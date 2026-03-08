#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "sqlite-vec",
#     "requests",
#     "pypdf",
#     "python-docx",
#     "openpyxl",
# ]
# ///
"""ai-organize — AI-powered file reorganizer, renamer, and deduplicator.

Modes
-----
  --scan   DIR          Walk a directory and emit a JSON file-list (metadata + snippets).
  --plan   DIR [flags]  Ask an LLM to produce a JSON reorganization plan.
  --apply  PLAN_FILE    Execute a previously generated plan (supports --dry-run).

Plan flags
----------
  --rename    Suggest more-descriptive filenames.
  --organize  Propose a logical folder structure.
  --flatten   Collapse deeply-nested paths into a flat layout.
  --dedupe    Flag files whose content is suspiciously similar.
  --top-level Non-recursive: only consider files in the root of DIR.
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import struct
import sys
from pathlib import Path

import requests

# ── Configuration ──────────────────────────────────────────────────────────────

OLLAMA_URL       = "http://localhost:11434/api/generate"
OLLAMA_EMBED_URL = "http://localhost:11434/api/embeddings"
MODEL            = os.environ.get("OLLAMA_MODEL",       "qwen3.5:9b")
EMBED_MODEL      = os.environ.get("OLLAMA_MODEL_EMBED", "qwen3-embedding:8b")

XDG_DATA_HOME  = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
SEARCH_DB_PATH = Path(XDG_DATA_HOME) / "ai-search" / "vectors.db"

# Characters of file content to pass as context per file
SNIPPET_LEN = 400
# Maximum files sent to the LLM in a single call (stay within context window).
# Each file can produce ~2 operations × ~80 tokens each, so 40 files ≈ 6 400
# tokens of output — safely within the num_predict budget below.
MAX_FILES_PER_BATCH = 40
# Cosine-distance threshold for declaring two files "duplicates" via embeddings
DUPE_THRESHOLD = 0.12

TEXT_EXTS = {
    ".nix", ".md", ".toml", ".yml", ".yaml", ".sh", ".bash", ".zsh",
    ".json", ".txt", ".py", ".rs", ".go", ".js", ".ts", ".jsx", ".tsx",
    ".css", ".html", ".csv", ".xml", ".ini", ".cfg", ".conf", ".env",
    ".r", ".sql", ".jl",
}
BINARY_EXTS = {".pdf", ".docx", ".xlsx"}
IGNORE_DIRS  = {".git", "node_modules", "vendor", "__pycache__", ".venv",
                "dist", "build", ".DS_Store", ".idea", ".vscode"}
IGNORE_FILES = {".DS_Store", ".gitkeep", "Thumbs.db", ".localized"}

# ── Code-project awareness ─────────────────────────────────────────────────────
# If any of these marker files exist at the root, we treat the directory as a
# code project and apply strict filtering so the LLM doesn't try to move source
# files, config files, lock files, or anything inside structural directories.
CODE_PROJECT_MARKERS = frozenset({
    "pyproject.toml", "setup.py", "setup.cfg",
    "package.json", "Cargo.toml", "go.mod",
    "flake.nix", "CMakeLists.txt", "Gemfile",
    "build.gradle", "pom.xml", "mix.exs",
})

# Extensions we *do* want to organize even inside a code project.
# Everything else (source, config, lock files) is left alone.
ORGANIZABLE_EXTS = frozenset({
    # Documents
    ".md", ".pdf", ".docx", ".doc", ".xlsx", ".xls", ".pptx", ".ppt",
    ".txt", ".rtf", ".odt", ".ods", ".odp",
    # Data
    ".csv", ".tsv", ".parquet", ".feather", ".arrow",
    # Notebooks
    ".ipynb",
    # Media
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico",
    ".mp4", ".mov", ".avi", ".mkv", ".mp3", ".wav",
    # Archives / deliverables
    ".zip", ".tar", ".gz", ".bz2", ".7z",
    # SQL / standalone scripts that aren't part of the project source
    ".sql",
})

# Specific filenames that are structural anchors and must never be moved,
# even if their extension is otherwise organizable.
STRUCTURAL_NAMES = frozenset({
    "README.md", "readme.md", "CHANGELOG.md", "changelog.md",
    "LICENSE", "LICENSE.md", "LICENSE.txt", "NOTICE",
    "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SECURITY.md",
    "CODEOWNERS", "OWNERS",
})

# Top-level directory names whose *contents* should not be touched in a code project.
STRUCTURAL_DIRS = frozenset({
    "src", "lib", "pkg", "cmd", "internal", "external",
    "app", "apps", "core",
    "tests", "test", "spec", "specs", "__tests__",
    ".github", ".gitlab", ".circleci", "ci", ".ci",
    "scripts",           # project's own scripts — don't reorganize them
    "modules",           # nix modules, etc.
})


# ── Project detection ─────────────────────────────────────────────────────────

def detect_code_project(directory: Path) -> str | None:
    """Return the marker filename if *directory* is a code project root, else None."""
    for marker in CODE_PROJECT_MARKERS:
        if (directory / marker).exists():
            return marker
    return None


def find_project_roots(scan_root: Path, recursive: bool) -> set[Path]:
    """Return the set of all code-project root directories relevant to *scan_root*.

    Three sources are considered:
    1. Ancestor directories of *scan_root* — handles the case where the user
       points the tool at a subdirectory of a project (e.g. ~/proj/docs).
    2. *scan_root* itself.
    3. All descendant directories — handles umbrella repos (e.g. ~/code with
       many individual sub-projects, each with their own pyproject.toml).

    Once a project root is found during descent, its children are not searched
    further (nested projects inside a project are uncommon and confusing).
    """
    roots: set[Path] = set()

    # 1. Check ancestors (nearest first, stop at the first hit)
    for ancestor in scan_root.parents:
        if detect_code_project(ancestor):
            roots.add(ancestor)
            break   # Only the nearest ancestor matters

    # 2. Check scan_root itself
    if detect_code_project(scan_root):
        roots.add(scan_root)
        # If the root is already a project, skip descendant search — sub-project
        # detection inside a project is handled by STRUCTURAL_DIRS filtering.
        return roots

    # 3. Walk descendants (only when recursive)
    if recursive:
        for dirpath_str, dirnames, _ in os.walk(scan_root):
            dirpath = Path(dirpath_str)
            # Prune ignored dirs in-place so os.walk won't descend into them
            dirnames[:] = [
                d for d in dirnames
                if d not in IGNORE_DIRS and not d.startswith(".")
            ]
            if detect_code_project(dirpath):
                roots.add(dirpath)
                dirnames.clear()    # Don't look for nested projects inside a project

    return roots


def find_enclosing_project(path: Path, project_roots: set[Path]) -> Path | None:
    """Return the deepest project root that is an ancestor of *path*, or None."""
    best: Path | None = None
    for proj_root in project_roots:
        try:
            path.relative_to(proj_root)
        except ValueError:
            continue
        # Prefer the deeper (more specific) root
        if best is None or len(proj_root.parts) > len(best.parts):
            best = proj_root
    return best


def is_organizable_in_project(path: Path, proj_root: Path) -> bool:
    """Return True when *path* is a file worth reorganizing inside a code project."""
    rel   = path.relative_to(proj_root)
    parts = rel.parts   # e.g. ("docs", "report.pdf") or ("README.md",)

    # Never move structural anchor files
    if path.name in STRUCTURAL_NAMES:
        return False

    # Skip files that live inside a structural directory
    if len(parts) > 1 and parts[0] in STRUCTURAL_DIRS:
        return False

    # Only include explicitly organizable extensions
    return path.suffix.lower() in ORGANIZABLE_EXTS


# ── Text Extraction ────────────────────────────────────────────────────────────

def extract_snippet(path: Path, max_chars: int = SNIPPET_LEN) -> str | None:
    """Return a short content preview for LLM context. Returns None for binaries we can't read."""
    ext = path.suffix.lower()

    if ext in TEXT_EXTS:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read(max_chars * 2)
            return text[:max_chars].strip() or None
        except OSError:
            return None

    if ext == ".pdf":
        try:
            from pypdf import PdfReader
            reader = PdfReader(str(path))
            text = ""
            for page in reader.pages:
                t = page.extract_text()
                if t:
                    text += " " + t
                if len(text) >= max_chars:
                    break
            return text.strip()[:max_chars] or None
        except Exception:
            return None

    if ext == ".docx":
        try:
            from docx import Document
            doc = Document(str(path))
            parts = [p.text.strip() for p in doc.paragraphs if p.text.strip()]
            return " ".join(parts)[:max_chars] or None
        except Exception:
            return None

    if ext == ".xlsx":
        try:
            from openpyxl import load_workbook
            wb = load_workbook(str(path), read_only=True, data_only=True)
            parts: list[str] = []
            for ws in wb.worksheets:
                for row in ws.iter_rows(values_only=True, max_row=8):
                    row_text = " ".join(str(c) for c in row if c is not None)
                    if row_text.strip():
                        parts.append(row_text)
            return " ".join(parts)[:max_chars] or None
        except Exception:
            return None

    return None  # Unknown / binary


# ── Directory Scanning ─────────────────────────────────────────────────────────

def scan_directory(
    directory: str,
    recursive: bool = True,
    all_files: bool = False,
) -> list[dict]:
    """Walk *directory* and return file descriptors with metadata.

    When *all_files* is False (the default), project-aware filtering is applied:

    - A fast pre-pass discovers all code-project root directories relevant to
      the scan: ancestor projects (handles scanning inside a project), the root
      itself, and descendant sub-projects (handles umbrella repos like ~/code).
    - Each file is matched against its deepest enclosing project root.  Files
      inside a project are restricted to organizable extensions (docs, data,
      media) and kept out of structural directories (src/, tests/, …).
    - Files with no enclosing project root (loose files in a general directory)
      are included without restriction.
    """
    root = Path(directory).resolve()
    if not root.is_dir():
        print(f"Error: {root} is not a directory.", file=sys.stderr)
        sys.exit(1)

    # ── Build project-root map ─────────────────────────────────────────────────
    project_roots: set[Path] = set()
    if not all_files:
        project_roots = find_project_roots(root, recursive)
        if project_roots:
            # Show project directory names (not marker filenames which repeat)
            names = [p.name for p in sorted(project_roots, key=lambda p: p.name)]
            print(
                f"Detected {len(project_roots)} code project(s): "
                f"{', '.join(names)}. "
                "Filtering to organizable assets inside each. "
                "Pass --all-files to include everything.",
                file=sys.stderr,
            )

    # ── Walk files ─────────────────────────────────────────────────────────────
    results: list[dict] = []
    total_seen = 0
    walk = root.rglob("*") if recursive else root.iterdir()

    for path in walk:
        if any(part in IGNORE_DIRS for part in path.parts):
            continue
        if path.name in IGNORE_FILES or path.name.startswith("."):
            continue
        if not path.is_file():
            continue

        total_seen += 1

        # Apply per-project filter when relevant
        if project_roots:
            proj_root = find_enclosing_project(path, project_roots)
            if proj_root and not is_organizable_in_project(path, proj_root):
                continue

        try:
            stat = path.stat()
        except OSError:
            continue

        rel     = str(path.relative_to(root))
        snippet = extract_snippet(path)

        results.append({
            "path":    rel,
            "name":    path.name,
            "ext":     path.suffix.lower(),
            "size":    stat.st_size,
            "snippet": snippet or "",
        })

    if project_roots:
        skipped = total_seen - len(results)
        if skipped:
            print(
                f"Skipped {skipped} source/config file(s). "
                f"{len(results)} organizable file(s) remain.",
                file=sys.stderr,
            )

    results.sort(key=lambda f: f["path"])
    return results


# ── LLM Helpers ────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = (
    "You are a meticulous file-system organizer. "
    "Analyse the provided file list and produce a reorganization plan as JSON. "
    "Never suggest deleting files — only rename, move, or flag duplicates. "
    "Output ONLY valid JSON — no prose, no markdown code fences."
)


def call_llm(prompt: str) -> str:
    """Send *prompt* to Ollama and return the raw text response."""
    payload: dict = {
        "model":      MODEL,
        "prompt":     prompt,
        "system":     SYSTEM_PROMPT,
        "stream":     False,
        "think":      False,      # suppress chain-of-thought on qwen3 models
        "keep_alive": -1,         # keep model loaded in VRAM for the whole session
        "options": {
            "temperature": 0.15,
            "num_predict": 8192,
        },
    }
    try:
        resp = requests.post(OLLAMA_URL, json=payload, timeout=600)
        resp.raise_for_status()
        return resp.json().get("response", "").strip()
    except requests.exceptions.RequestException as e:
        print(f"Error calling Ollama: {e}", file=sys.stderr)
        sys.exit(1)


def extract_json(text: str) -> dict | list:
    """Pull the first complete JSON object or array out of *text*."""
    # Strip <think>…</think> blocks emitted by reasoning models (qwen3, etc.)
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    # Strip optional markdown code fences
    text = re.sub(r"^```(?:json)?\s*", "", text.strip())
    text = re.sub(r"\s*```$", "", text.strip())

    for start_ch, end_ch in [('{', '}'), ('[', ']')]:
        start = text.find(start_ch)
        if start == -1:
            continue
        depth       = 0
        in_string   = False
        escape_next = False
        for i, ch in enumerate(text[start:], start):
            if escape_next:
                escape_next = False
                continue
            if ch == '\\' and in_string:
                escape_next = True
                continue
            if ch == '"':
                in_string = not in_string
                continue
            if in_string:
                continue
            if ch == start_ch:
                depth += 1
            elif ch == end_ch:
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start : i + 1])
                    except json.JSONDecodeError:
                        break

    raise ValueError(f"No valid JSON in LLM response:\n{text[:600]}")


# ── Plan Generation ────────────────────────────────────────────────────────────
#
# Strategy
# --------
# Old approach: send every file with snippets to the LLM → O(N/40) calls,
#               each requiring ~8 000 token output budget. Hits timeouts at scale.
#
# New approach:
#   --organize / --flatten   Two-phase
#     Phase 1 (1 call)     : send all file *paths* (no snippets) → folder taxonomy
#     Phase 2 (N/150 calls): classify files into that taxonomy → compact output
#   --rename                 Snippet-based, but pre-filtered to obvious candidates
#     (1–2 calls for most dirs)
#
# Result: 739 files → ~6 LLM calls instead of 19.

# Maximum files per classification call (output is ~50 tokens/file: much smaller
# than a full plan operation, so we can use much larger batches).
MAX_CLASSIFY_BATCH = 150
# Maximum files per rename-suggestion call (needs snippets, so smaller batches).
MAX_RENAME_BATCH   = 30


# ── Rename candidate detection ─────────────────────────────────────────────────

_GENERIC_STEM_RE = [
    # Generic document names: doc1, report2, file_3, data, untitled, new copy…
    re.compile(
        r'^(doc|document|file|report|data|untitled|new|copy|image|img|photo|'
        r'pic|scan|draft|temp|tmp|attachment|download|export|output|result)\s*[\d_\-]*$',
        re.IGNORECASE,
    ),
    re.compile(r'^[A-Z]{2,5}\d{3,}$'),               # IMG0001, DSC09876, DCIM0042
    re.compile(r'^\d{4}-\d{2}-\d{2}$'),              # 2024-01-15  (date, no description)
    re.compile(r'^\d{8,}$'),                          # purely numeric (timestamps, IDs)
    re.compile(r'^[a-f0-9]{8,}$', re.IGNORECASE),    # hash-named files
]

def is_rename_candidate(filename: str) -> bool:
    """Return True if the filename stem looks too generic to be self-describing."""
    stem = Path(filename).stem
    return any(pat.match(stem) for pat in _GENERIC_STEM_RE)


# ── Phase 1: folder taxonomy ───────────────────────────────────────────────────

def plan_folder_taxonomy(files: list[dict], root: str) -> list[str]:
    """One LLM call: derive a folder structure from file paths alone (no snippets).

    Sending only paths keeps the prompt tiny — all 700+ files fit comfortably —
    and the output is a small JSON array of folder names.
    """
    paths_text = "\n".join(f"  {f['path']}" for f in files)

    prompt = f"""You are organizing files in: {root}

Given the file list below, propose a clean, minimal folder structure.

RULES:
- 5 to 15 folders total
- Maximum 2 levels of depth
- Lowercase kebab-case names
- Name folders after actual content themes (avoid "misc", "other", "files")
- Every file must fit into at least one folder

FILES:
{paths_text}

Output ONLY a JSON array of folder path strings.
Example: ["reports/2024", "data/raw", "notebooks", "assets/images"]

JSON:"""

    raw = call_llm(prompt)
    try:
        result = extract_json(raw)
        if isinstance(result, list):
            return [str(f).strip().rstrip("/") for f in result if isinstance(f, str) and f.strip()]
    except (ValueError, KeyError):
        pass
    return []


# ── Phase 2: file classification ───────────────────────────────────────────────

def classify_files_to_folders(
    files: list[dict],
    folders: list[str],
    root: str,
) -> list[dict]:
    """Assign each file to a folder from the taxonomy. Large batches (150 files)
    are fine here because each output entry is only ~50 tokens.
    """
    all_ops: list[dict] = []
    folders_text = "\n".join(f"  {f}" for f in folders)
    total = (len(files) + MAX_CLASSIFY_BATCH - 1) // MAX_CLASSIFY_BATCH

    for i in range(0, len(files), MAX_CLASSIFY_BATCH):
        batch = files[i : i + MAX_CLASSIFY_BATCH]
        n     = i // MAX_CLASSIFY_BATCH + 1
        print(f"  Classify batch {n}/{total} ({len(batch)} files)…", file=sys.stderr)

        files_text = "\n".join(f"  {f['path']}" for f in batch)
        prompt = f"""Assign each file to the most appropriate folder from the list below.

AVAILABLE FOLDERS (in: {root}):
{folders_text}

FILES TO CLASSIFY:
{files_text}

RULES:
- Assign every file to exactly one folder
- Output ONLY a JSON array — no prose, no fences

JSON: [{{"file": "original/path.ext", "folder": "target/folder"}}, ...]"""

        raw = call_llm(prompt)
        try:
            assignments = extract_json(raw)
            if not isinstance(assignments, list):
                print(f"  Warning: unexpected response for classify batch {n}, skipping.", file=sys.stderr)
                continue
        except (ValueError, KeyError):
            print(f"  Warning: could not parse classify batch {n}, skipping.", file=sys.stderr)
            continue

        seen_mkdirs: set[str] = set()
        for a in assignments:
            if not isinstance(a, dict):
                continue
            src    = a.get("file",   "").strip()
            folder = a.get("folder", "").strip().rstrip("/")
            if not src or not folder:
                continue
            dst = f"{folder}/{Path(src).name}"
            if src == dst:
                continue
            if folder not in seen_mkdirs:
                all_ops.append({"op": "mkdir", "path": folder})
                seen_mkdirs.add(folder)
            all_ops.append({"op": "move", "from": src, "to": dst,
                            "reason": f"Organized into {folder}"})

    return all_ops


# ── Rename pass (snippet-based, pre-filtered) ──────────────────────────────────

_RENAME_SCHEMA = """\
[
  {"from": "old-name.pdf", "to": "better-name.pdf", "reason": "…"},
  …
]"""

def suggest_renames(candidates: list[dict], root: str) -> list[dict]:
    """Suggest better names only for files that look non-descriptive.

    Uses content snippets (so smaller batches), but the candidate list is
    typically tiny after pre-filtering, so total LLM calls stay low.
    """
    all_ops: list[dict] = []
    total = (len(candidates) + MAX_RENAME_BATCH - 1) // MAX_RENAME_BATCH

    for i in range(0, len(candidates), MAX_RENAME_BATCH):
        batch = candidates[i : i + MAX_RENAME_BATCH]
        n     = i // MAX_RENAME_BATCH + 1
        print(f"  Rename batch {n}/{total} ({len(batch)} files)…", file=sys.stderr)

        files_text = "\n".join(
            f"  {f['path']} | preview: \"{f['snippet'].replace(chr(10), ' ').strip()[:250]}\""
            if f["snippet"] else f"  {f['path']}"
            for f in batch
        )
        prompt = f"""Suggest better filenames for the files below. Only rename when the new name
is clearly more descriptive than the original. Keep the file in its current directory.

RULES:
- Lowercase kebab-case. Keep the original extension.
- Output ONLY a JSON array. Omit files that don't need renaming.

FILES (in: {root}):
{files_text}

SCHEMA: {_RENAME_SCHEMA}

JSON:"""

        raw = call_llm(prompt)
        try:
            renames = extract_json(raw)
            if not isinstance(renames, list):
                continue
        except (ValueError, KeyError):
            print(f"  Warning: could not parse rename batch {n}, skipping.", file=sys.stderr)
            continue

        for r in renames:
            if not isinstance(r, dict):
                continue
            src = r.get("from", "").strip()
            dst = r.get("to",   "").strip()
            if not src or not dst or src == dst:
                continue
            # Ensure the rename stays in the same directory
            src_parent = str(Path(src).parent)
            dst_name   = Path(dst).name
            normalized_dst = f"{src_parent}/{dst_name}" if src_parent != "." else dst_name
            all_ops.append({"op": "rename", "from": src, "to": normalized_dst,
                            "reason": r.get("reason", "")})

    return all_ops


# ── Top-level plan dispatcher ──────────────────────────────────────────────────

def generate_plan(
    files: list[dict],
    directory: str,
    do_rename: bool,
    do_organize: bool,
    do_flatten: bool,
) -> dict:
    """Dispatch to the most efficient strategy for the requested operations."""
    all_ops:   list[dict] = []
    summaries: list[str]  = []

    # ── Organize / Flatten: two-phase ─────────────────────────────────────────
    if do_organize or do_flatten:
        print(f"  Phase 1: deriving folder structure from {len(files)} paths…",
              file=sys.stderr)

        if do_flatten:
            deep = sum(1 for f in files if f["path"].count("/") > 1)
            if deep:
                print(f"  {deep} deeply-nested file(s) will be flattened.", file=sys.stderr)

        folders = plan_folder_taxonomy(files, directory)

        if not folders:
            print("  Warning: no folder structure proposed, skipping organize step.",
                  file=sys.stderr)
        else:
            preview = ", ".join(folders[:6]) + ("…" if len(folders) > 6 else "")
            print(f"  Proposed {len(folders)} folder(s): {preview}", file=sys.stderr)
            print(f"  Phase 2: classifying {len(files)} file(s)…", file=sys.stderr)

            ops = classify_files_to_folders(files, folders, directory)
            all_ops.extend(ops)
            n_moves = sum(1 for o in ops if o.get("op") == "move")
            summaries.append(f"Organized {n_moves} file(s) into {len(folders)} folder(s).")

    # ── Rename: pre-filtered snippet pass ─────────────────────────────────────
    if do_rename:
        candidates = [f for f in files if is_rename_candidate(f["name"])]
        if candidates:
            print(f"  {len(candidates)} rename candidate(s) identified.", file=sys.stderr)
            ops = suggest_renames(candidates, directory)
            all_ops.extend(ops)
            n = len(ops)
            if n:
                summaries.append(f"Suggested {n} rename(s).")
        else:
            print("  No rename candidates found (all filenames look descriptive).",
                  file=sys.stderr)

    # Deduplicate mkdir operations accumulated across phases
    seen_mkdirs: set[str] = set()
    deduped: list[dict] = []
    for op in all_ops:
        if op.get("op") == "mkdir":
            p = op.get("path", "")
            if p not in seen_mkdirs:
                seen_mkdirs.add(p)
                deduped.append(op)
        else:
            deduped.append(op)

    return {"operations": deduped, "summary": " ".join(s for s in summaries if s)}


# ── Deduplication ──────────────────────────────────────────────────────────────

def _cosine_dist(a: list[float], b: list[float]) -> float:
    mag_a = sum(x * x for x in a) ** 0.5
    mag_b = sum(x * x for x in b) ** 0.5
    if mag_a == 0 or mag_b == 0:
        return 1.0
    dot = sum(x * y for x, y in zip(a, b))
    return max(0.0, 1.0 - dot / (mag_a * mag_b))


def _groups_from_pairs(pairs: list[tuple[str, str]]) -> list[set[str]]:
    groups: list[set[str]] = []
    for p, q in pairs:
        merged = False
        for grp in groups:
            if p in grp or q in grp:
                grp.add(p)
                grp.add(q)
                merged = True
                break
        if not merged:
            groups.append({p, q})
    return groups


def _dedupe_via_db(directory: str) -> list[dict] | None:
    """Use cached vectors from the ai-search DB; return None if unavailable."""
    if not SEARCH_DB_PATH.exists():
        return None

    abs_dir = str(Path(directory).resolve())
    prefix  = abs_dir.rstrip("/") + "/"

    try:
        import sqlite_vec  # type: ignore[import-untyped]
        conn = sqlite3.connect(SEARCH_DB_PATH)
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)
        cur = conn.cursor()
        cur.execute(
            "SELECT m.filepath, e.embedding "
            "FROM file_metadata m "
            "JOIN file_embeddings e ON m.rowid = e.rowid "
            "WHERE m.filepath LIKE ?",
            (prefix + "%",),
        )
        rows = cur.fetchall()
        conn.close()
    except Exception as e:
        print(f"Note: Could not read ai-search DB ({e}). Falling back to LLM.", file=sys.stderr)
        return None

    if not rows:
        return None

    print(f"  Using {len(rows)} cached embeddings from ai-search database.", file=sys.stderr)

    # Average multiple chunks per file into a single representative vector
    file_vecs: dict[str, list[float]]  = {}
    file_cnts: dict[str, int]          = {}
    vec_len: int | None                = None

    for filepath, vec_bytes in rows:
        if vec_bytes is None:
            continue
        rel = filepath.removeprefix(prefix)
        if vec_len is None:
            vec_len = len(vec_bytes) // 4
        vec = list(struct.unpack(f"<{vec_len}f", vec_bytes))
        if rel in file_vecs:
            file_vecs[rel] = [a + b for a, b in zip(file_vecs[rel], vec)]
            file_cnts[rel] += 1
        else:
            file_vecs[rel] = vec
            file_cnts[rel] = 1

    averaged = [
        (rel, [v / file_cnts[rel] for v in vec])
        for rel, vec in file_vecs.items()
    ]

    pairs: list[tuple[str, str]] = []
    n = len(averaged)
    for i in range(n):
        for j in range(i + 1, n):
            if _cosine_dist(averaged[i][1], averaged[j][1]) <= DUPE_THRESHOLD:
                pairs.append((averaged[i][0], averaged[j][0]))

    return [
        {"op": "duplicate", "files": sorted(grp),
         "reason": "Very similar content in ai-search index — review and consolidate"}
        for grp in _groups_from_pairs(pairs)
    ]


def _dedupe_via_llm(files: list[dict]) -> list[dict]:
    """Ask the LLM to identify likely duplicates from names + snippets."""
    file_text = _build_file_table(files)
    prompt = f"""Identify groups of files that appear to have duplicate or near-duplicate content, based on their filenames and content previews.

FILES:
{file_text}

Output ONLY a JSON array of duplicate groups. Each group is an array of relative file paths.
If no duplicates are found, output an empty array: []

Example: [["report.pdf", "report-copy.pdf"], ["notes-v1.txt", "notes-v2.txt"]]

JSON output:"""

    raw = call_llm(prompt)
    try:
        groups = extract_json(raw)
        if not isinstance(groups, list):
            return []
        ops: list[dict] = []
        for grp in groups:
            if isinstance(grp, list) and len(grp) >= 2:
                ops.append({
                    "op":     "duplicate",
                    "files":  grp,
                    "reason": "LLM identified similar content — review and consolidate",
                })
        return ops
    except (ValueError, KeyError):
        return []


def find_duplicates(directory: str, files: list[dict]) -> list[dict]:
    """Find duplicate files: tries the ai-search DB first, then falls back to LLM."""
    db_result = _dedupe_via_db(directory)
    if db_result is not None:
        return db_result
    print("  No ai-search index found for this directory — using LLM for duplicate detection.",
          file=sys.stderr)
    return _dedupe_via_llm(files)


# ── Plan Application ───────────────────────────────────────────────────────────

def apply_plan(plan: dict, root_dir: str, dry_run: bool) -> None:
    """Apply a reorganization plan to the filesystem."""
    root = Path(root_dir).resolve()
    ops  = plan.get("operations", [])

    applied = skipped = errors = 0

    for op in ops:
        kind = op.get("op")

        if kind == "mkdir":
            target = root / op.get("path", "")
            if dry_run:
                print(f"  [dry-run] mkdir   {op['path']}/")
            else:
                try:
                    target.mkdir(parents=True, exist_ok=True)
                    applied += 1
                except OSError as e:
                    print(f"  Error creating {target}: {e}", file=sys.stderr)
                    errors += 1

        elif kind in ("move", "rename"):
            src = root / op.get("from", "")
            dst = root / op.get("to",   "")
            if not src.exists():
                print(f"  Skip (not found): {op.get('from')}", file=sys.stderr)
                skipped += 1
                continue
            if dst.exists():
                print(f"  Skip (exists):    {op.get('to')}", file=sys.stderr)
                skipped += 1
                continue
            if dry_run:
                print(f"  [dry-run] {kind:<6}  {op.get('from')}  →  {op.get('to')}")
            else:
                try:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(src), str(dst))
                    applied += 1
                except OSError as e:
                    print(f"  Error moving {src} → {dst}: {e}", file=sys.stderr)
                    errors += 1

        elif kind == "duplicate":
            # Informational only — never auto-delete
            if dry_run:
                files_str = ", ".join(op.get("files", []))
                print(f"  [info]    dupes   {files_str}")

    if not dry_run:
        print(
            f"\n  Applied: {applied}  |  Skipped: {skipped}  |  Errors: {errors}",
            file=sys.stderr,
        )


# ── Entry Point ────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="AI-powered file reorganizer, renamer, and deduplicator"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--scan",  metavar="DIR",       help="Scan and emit file list as JSON")
    group.add_argument("--plan",  metavar="DIR",       help="Generate a reorganization plan")
    group.add_argument("--apply", metavar="PLAN_FILE", help="Apply a saved plan")

    # Plan-mode flags
    parser.add_argument("--rename",    action="store_true", help="Suggest better filenames")
    parser.add_argument("--organize",  action="store_true", help="Suggest folder structure")
    parser.add_argument("--flatten",   action="store_true", help="Flatten nested paths")
    parser.add_argument("--dedupe",    action="store_true", help="Flag near-duplicate files")
    parser.add_argument("--top-level", action="store_true", help="Only scan top-level files (non-recursive)")
    parser.add_argument(
        "--all-files", action="store_true",
        help="Disable code-project filtering: include source, config, and lock files"
    )
    parser.add_argument(
        "--from-scan", metavar="FILE",
        help="Load pre-scanned file list from a JSON file instead of re-scanning (output of --scan)"
    )

    # Apply-mode flags
    parser.add_argument("--dry-run", action="store_true", help="Preview without making changes")
    parser.add_argument(
        "--root", metavar="DIR",
        help="Root directory for --apply (overrides the 'root' stored in the plan)",
    )

    args = parser.parse_args()

    # ── Scan ──────────────────────────────────────────────────────────────────
    if args.scan:
        files = scan_directory(args.scan, recursive=not args.top_level, all_files=args.all_files)
        print(json.dumps(files, indent=2))
        sys.exit(0)

    # ── Plan ──────────────────────────────────────────────────────────────────
    if args.plan:
        # Default to all structural operations when none are specified
        if not any([args.rename, args.organize, args.flatten, args.dedupe]):
            args.rename   = True
            args.organize = True
            args.dedupe   = True

        if args.from_scan:
            scan_path = Path(args.from_scan)
            if not scan_path.exists():
                print(f"Error: scan file not found: {scan_path}", file=sys.stderr)
                sys.exit(1)
            with open(scan_path) as fh:
                files = json.load(fh)
            print(f"Loaded {len(files)} file(s) from pre-scan.", file=sys.stderr)
        else:
            files = scan_directory(args.plan, recursive=not args.top_level, all_files=args.all_files)

        if not files:
            result: dict = {"root": str(Path(args.plan).resolve()),
                            "operations": [], "summary": "No files found."}
            print(json.dumps(result, indent=2))
            sys.exit(0)

        print(f"Scanned {len(files)} file(s).", file=sys.stderr)

        if len(files) > 300:
            print(
                f"Warning: {len(files)} files found. Consider using --top-level "
                "or a more targeted subdirectory.",
                file=sys.stderr,
            )

        ops: list[dict] = []
        summary = ""

        if args.rename or args.organize or args.flatten:
            plan = generate_plan(
                files, args.plan,
                do_rename=args.rename,
                do_organize=args.organize,
                do_flatten=args.flatten,
            )
            ops.extend(plan.get("operations", []))
            summary = plan.get("summary", "")

        if args.dedupe:
            print("Detecting duplicates…", file=sys.stderr)
            dupe_ops = find_duplicates(args.plan, files)
            ops.extend(dupe_ops)
            n = len(dupe_ops)
            if n:
                suffix = f"Found {n} duplicate group{'s' if n != 1 else ''}."
                summary = (summary + " " + suffix).strip()

        result = {
            "root":       str(Path(args.plan).resolve()),
            "operations": ops,
            "summary":    summary,
        }
        print(json.dumps(result, indent=2))
        sys.exit(0)

    # ── Apply ─────────────────────────────────────────────────────────────────
    if args.apply:
        plan_path = Path(args.apply)
        if not plan_path.exists():
            print(f"Error: Plan file not found: {plan_path}", file=sys.stderr)
            sys.exit(1)

        with open(plan_path) as fh:
            plan = json.load(fh)

        root = args.root or plan.get("root")
        if not root:
            print(
                "Error: --root is required when the plan has no embedded root path.",
                file=sys.stderr,
            )
            sys.exit(1)

        if not Path(root).is_dir():
            print(f"Error: Root directory does not exist: {root}", file=sys.stderr)
            sys.exit(1)

        apply_plan(plan, root, dry_run=args.dry_run)
        sys.exit(0)


if __name__ == "__main__":
    main()
