# AI Scripts Consolidation Plan

## Current state

14 scripts across 4 domains (data, gen, git, search), all powered by Ollama. Each bash script independently implements the same infrastructure: Ollama lifecycle, clipboard, temp-file cleanup, think-block stripping, JSON payload construction, and response parsing. Two Python scripts (`ai-search.py` and `ai-organize.py`) both directly manipulate the same SQLite + sqlite-vec database but share no code — `ai-organize.py` duplicates the schema, connection setup, and embedding logic, and re-implements caching/write-back with its own knowledge of the DB layout.

The scripts are packaged via `scripts.nix` as `writeShellScriptBin` wrappers that `exec bash` into the real scripts. Python backends are invoked via `uv run` (for inline dependency resolution).

---

## Phase 1 — Shared bash library (`scripts/lib/common.sh`)

**Goal:** Extract every repeated bash pattern into sourceable functions. Each `ai-*.sh` script drops ~40–60 lines and gains consistency.

### Functions to extract

| Function | Current duplication | Notes |
|----------|-------------------|-------|
| `ensure_ollama` | 11 scripts (inline blocks) | Startup, polling (30s), model-pull check. `ai-search.sh` already wraps this as a function — promote that pattern. |
| `clip_copy` | 6 scripts (identical) | pbcopy / xclip / wl-copy cascade. |
| `ollama_generate` | 7 scripts | Accepts: prompt file, model, temperature, num_predict, num_ctx, think (bool). Writes JSON payload via Python, curls to `/api/generate`, returns response file path. Replaces the repeated python3→json→curl→parse chain. |
| `parse_response` | 7 scripts | Reads Ollama JSON response file, extracts `.response`, prints to stdout. Exits with error message if model not pulled. |
| `strip_think_blocks` | 6 scripts (3 awk, 3 Python regex) | Standardise on a single approach (awk is simpler, no Python dep). Reads stdin, writes stdout. |
| `term_width` | 6 scripts | `tput cols` with fallback to 80, capped at 100. |
| `make_tempfiles` | All scripts | Accepts list of variable names, creates temp files, registers trap. |

### Migration per script

Each script changes from:

```bash
# 60 lines of boilerplate (clipboard, ollama startup, payload, curl, parse, strip)
```

to:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

ensure_ollama "$MODEL"
RESPONSE=$(ollama_generate "$PROMPT_FILE" "$MODEL" \
  --temperature 0.2 --num_predict 200 --num_ctx 4096)
CLEAN=$(echo "$RESPONSE" | strip_think_blocks)
```

### Rollout order

1. Create `scripts/lib/common.sh` with all functions, plus a small test script
2. Migrate one simple script first (`ai-explain.sh` — no action menu, no clipboard)
3. Migrate the gen/ scripts (`ai-cmd`, `ai-narrative`, `ai-slide-copy`) — these are structurally identical
4. Migrate git/ scripts (`ai-commit`, `ai-pr`)
5. Migrate search/ shell wrappers (`ai-search.sh`, `ai-chat.sh`)
6. Migrate data/ shell wrappers (`ai-organize.sh`, `ai-duck.sh`)
7. Update `scripts.nix` — no changes needed to the `writeShellScriptBin` wrappers since they already `exec bash` into the real scripts

### Risk

Low. Pure extraction refactor — every function is already battle-tested across 11 scripts. Behaviour is identical; only the source location changes. Each script can be migrated and tested independently.

### Status: COMPLETE

Created `scripts/lib/common.sh` (212 lines) and migrated all 10 bash scripts. Net result: 529 lines of duplicated code eliminated. All scripts pass `bash -n` syntax checks and zero remaining inline implementations of the extracted functions.

---

## Phase 2 — Python embeddings library (`scripts/lib/embeddings.py`)

**Goal:** Single source of truth for vector DB schema, connection management, embedding calls, chunking, and text extraction. Both `ai-search.py` and `ai-organize.py` import from it instead of maintaining parallel implementations.

### What moves into `embeddings.py`

```
scripts/lib/embeddings.py
├── Config
│   ├── DB_PATH (XDG-aware)
│   ├── EMBED_MODEL (env override)
│   ├── EMBED_DIM = 1024
│   ├── CHUNK_SIZE = 4000
│   └── OVERLAP = 200
│
├── DB layer
│   ├── init_db() → Connection        # create tables, load sqlite-vec, WAL
│   ├── open_db() → Connection        # read-only open, fail if missing
│   └── clear_db()                    # delete DB + WAL + SHM
│
├── Embedding
│   ├── get_embedding(text) → list[float]
│   ├── get_embeddings_batch(texts) → list[list[float]]   # future: batch endpoint
│   └── vec_to_bytes(vec) → bytes     # struct.pack wrapper
│
├── Text extraction
│   ├── extract_text(path) → str | None    # dispatches on extension
│   ├── chunk_text(text, size, overlap) → list[str]
│   ├── TEXT_EXTS, BINARY_EXTS, IGNORE_DIRS  # unified constants
│   └── is_text_file(path) → bool
│
├── Indexing
│   ├── index_directory(conn, directory)      # incremental, mtime-aware
│   └── check_dir_indexed(conn, directory) → bool
│
├── Retrieval
│   ├── search(conn, query, top_k, threshold) → list[dict]
│   └── retrieve_with_chunks(conn, query, scope, top_k) → list[dict]
│
└── Cache helpers (for ai-organize)
    ├── load_cached_embeddings(directory) → dict[str, list[float]] | None
    └── save_embeddings(entries: list[tuple[str, list[float]]])
```

### What stays in each consumer

**`ai-search.py`** keeps: CLI arg parsing, `--status` formatting, `main()`. Drops: `init_db`, `get_embedding`, `extract_text`, `chunk_text`, `is_text_file`, `index_directory`, `search`, `check_dir`, `clear_db`, all constants. ~250 lines removed, ~80 lines remain.

**`ai-chat.py`** keeps: prompt construction, `generate_answer`, `chat()` pipeline, CLI. Drops: `get_embedding`, `open_db`, `retrieve`, DB path constants, vec packing. ~100 lines removed, ~100 lines remain.

**`ai-organize.py`** keeps: scanning, clustering (HDBSCAN, composite distance), planning, apply logic, rename detection, code-project awareness. Drops: `_load_cached_embeddings`, `_save_embeddings_to_db`, `_dedupe_knn_from_db`, the duplicated `SEARCH_DB_PATH`/`OLLAMA_EMBED_URL`/`TEXT_EXTS`/`BINARY_EXTS`/`IGNORE_DIRS` constants, and the inline `sqlite_vec` connection boilerplate (~4 separate connection blocks). `embed_files()` calls into the library instead of managing its own Ollama HTTP calls. ~200 lines removed.

### Constants currently duplicated

| Constant | ai-search.py | ai-chat.py | ai-organize.py |
|----------|-------------|-----------|---------------|
| DB_PATH | `~/.local/share/ai-search/vectors.db` | same | same |
| EMBED_MODEL | `qwen3-embedding:0.6b` | `qwen3-embedding:0.6b` | `qwen3-embedding:0.6b` |
| EMBED_DIM | 1024 (implicit in schema) | implicit | implicit |
| CHUNK_SIZE | 4000 | — | — (uses SNIPPET_LEN=400 differently) |
| OVERLAP | 200 | — | — |
| TEXT_EXTS | 20 extensions | — | 26 extensions (superset) |
| BINARY_EXTS | 3 extensions | — | 3 extensions (same) |
| IGNORE_DIRS | 6 dirs | — | 10 dirs (superset) |
| Cosine threshold | 0.8 | 0.8 | 0.12 (dupe) |

The library unifies `TEXT_EXTS` and `IGNORE_DIRS` to the superset. `ai-organize.py` keeps its own `DUPE_THRESHOLD` and `SNIPPET_LEN` since those serve a different purpose (deduplication, not search relevance).

### Import path

Since these scripts use `uv run` with inline `# /// script` dependency blocks, the library needs to be importable. Two options:

**Option A — Relative import with sys.path (simpler, no packaging):**
```python
# At top of ai-search.py
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from embeddings import init_db, index_directory, search, ...
```
The `uv run` inline deps already handle `sqlite-vec`, `requests`, etc.

**Option B — Make `scripts/lib/` a proper package with pyproject.toml:**
More correct, but adds packaging overhead for what are still CLI scripts run via `uv run`. Probably overkill now; consider if/when the scripts grow into a proper package.

**Recommendation:** Option A. It matches the existing project style (scripts, not packages) and requires zero changes to `scripts.nix`.

### Rollout order

1. Create `scripts/lib/embeddings.py` with all functions extracted from `ai-search.py` (it has the cleanest implementations)
2. Refactor `ai-search.py` to import from it — run `ai-search --index` and `ai-search <query>` to verify identical behaviour
3. Refactor `ai-chat.py` to import from it — verify RAG pipeline produces same results
4. Refactor `ai-organize.py` — this is the biggest change; the cache-load and save functions need to delegate to the library's DB layer. Test with `--scan`, `--plan`, and `--dedupe` on a real directory.
5. Run `test_ai_organize.py` to confirm no regressions in clustering math

### Risk

Medium. The embedding and DB code is well-understood, but `ai-organize.py` has subtle interactions with the DB (it averages multi-chunk embeddings per file, uses a different text representation for embedding, and writes back with a different snippet format). The library needs to accommodate these without breaking the simpler search use case. This is solvable with clear function signatures and the `load_cached_embeddings`/`save_embeddings` helpers that encapsulate the organize-specific patterns.

### Status: COMPLETE

Created `scripts/lib/embeddings.py` (660 lines) and refactored all 3 Python consumers:
- `ai-search.py`: 391 → 66 lines (dropped 83%)
- `ai-chat.py`: 231 → 140 lines (dropped 39%)
- `ai-organize.py`: 2472 → 2313 lines (dropped 6%, but eliminated all DB/embedding duplication)
- All 103 unit tests in `test_ai_organize.py` pass
- Zero remaining inline `get_embedding`, `init_db`, `open_db`, `struct.pack`, or `OLLAMA_EMBED_URL` definitions outside the library
- Key design decisions:
  - `get_embedding()` accepts `timeout` and `keep_alive` kwargs to accommodate consumer differences (10s/30s/120s)
  - `is_text_file()` and `index_directory()` accept `extra_text_exts`/`extra_ignore_dirs` for ai-organize's superset
  - `load_cached_embeddings()` and `save_embeddings()` handle the organize-specific multi-chunk averaging and single-row-per-file write-back patterns
  - Import via `sys.path.insert(0, ...)` — no packaging changes needed, `uv run` inline deps continue to work

---

## Phase 3 — Shared Ollama Python client (`scripts/lib/ollama.py`)

**Goal:** Replace the 3 independent `requests.post()` call patterns across the Python scripts with a thin client that handles connection, retries, and error formatting.

```
scripts/lib/ollama.py
├── Constants
│   ├── OLLAMA_BASE_URL = "http://localhost:11434"
│   ├── CHAT_MODEL (env override)
│   └── EMBED_MODEL (env override)
│
├── generate(prompt, model, system, temperature, num_predict, num_ctx, think, keep_alive, timeout) → str
├── embed(text, model, timeout, keep_alive) → list[float]
└── is_running() → bool
```

### Current duplication

| Pattern | ai-chat.py | ai-organize.py | embeddings.py |
|---------|-----------|----------------|---------------|
| `requests.post(…/api/generate, …)` | `generate_answer()` timeout=120 | `call_llm()` timeout=600, system prompt, keep_alive=-1 | — |
| `requests.post(…/api/embeddings, …)` | — | — | `get_embedding()` variable timeout/keep_alive |
| `OLLAMA_GENERATE_URL` constant | imported from embeddings | imported as `OLLAMA_URL` | defined |
| `OLLAMA_EMBED_URL` constant | — | imported | defined |
| Model env-var reading | imported `CHAT_MODEL` | `MODEL = os.environ.get(…)` | `EMBED_MODEL`, `CHAT_MODEL` defined |
| Error handling | `json.dumps({"error": …})` + exit | `print(…, stderr)` + exit | `print(…, stderr)` + exit |

### What moves into `ollama.py`

1. **`generate()`** — accepts all the knobs (model, prompt, system, temperature, num_predict, num_ctx, think, keep_alive, timeout), builds payload, POSTs to `/api/generate`, returns `.response` string. Error handling prints to stderr + exits (consistent with embed).
2. **`embed()`** — thin wrapper that replaces `get_embedding()` in `embeddings.py`. Same signature (text, model, timeout, keep_alive).
3. **`is_running()`** — GET `/api/tags` to check if Ollama is responsive.
4. **Constants** — `OLLAMA_BASE_URL`, `CHAT_MODEL`, `EMBED_MODEL` move here. `embeddings.py` imports `embed` and model constants from `ollama.py` instead of defining its own.

### What stays in each consumer

- **`ai-chat.py`**: keeps `build_prompt()`, `chat()` pipeline, CLI. Replaces inline `generate_answer()` with `from ollama import generate`.
- **`ai-organize.py`**: keeps `call_llm()` as a thin wrapper that passes its `SYSTEM_PROMPT` and `keep_alive=-1` to `generate()`. Or inlines the call directly.
- **`embeddings.py`**: drops `get_embedding()`, `OLLAMA_EMBED_URL`, `OLLAMA_GENERATE_URL`, `EMBED_MODEL`, `CHAT_MODEL`. Imports `embed` from `ollama.py`.

### Rollout order

1. Create `scripts/lib/ollama.py` with `generate()`, `embed()`, `is_running()`, constants
2. Refactor `embeddings.py` to import `embed` from `ollama.py` (replaces its `get_embedding` + URL constants)
3. Refactor `ai-chat.py` to import `generate` from `ollama.py` (replaces `generate_answer`)
4. Refactor `ai-organize.py` to import `generate` from `ollama.py` (replaces inline `requests.post` in `call_llm`)
5. Run `test_ai_organize.py` to confirm no regressions

### Risk

Low. Thin wrapper over `requests.post()` with consistent timeout and error handling. The only subtlety is that `ai-organize.py`'s `call_llm` uses a system prompt and `keep_alive=-1` while `ai-chat.py`'s `generate_answer` does not — the unified `generate()` handles both via optional kwargs.

### Status: COMPLETE

Created `scripts/lib/ollama.py` (138 lines) and refactored all consumers:
- `embeddings.py`: 660 → 633 lines. Replaced inline `get_embedding()` HTTP call and `OLLAMA_EMBED_URL`/`OLLAMA_GENERATE_URL`/`EMBED_MODEL`/`CHAT_MODEL` constants with imports from `ollama.py`. `get_embedding()` now delegates to `ollama.embed()`. Also dropped `import requests` entirely — embeddings.py no longer makes any HTTP calls directly.
- `ai-chat.py`: 140 → 112 lines. Eliminated `generate_answer()` function and `import requests`. Now calls `ollama.generate()` directly with the same parameters (temperature=0.3, num_predict=600, num_ctx=8192, timeout=120).
- `ai-organize.py`: 2313 → 2296 lines. `call_llm()` reduced from 20 lines to 7 (thin wrapper passing system prompt + organize-specific params to `ollama.generate()`). Dropped `import requests`, `import struct`, and `MODEL` env-var read — all now handled by the library layer.
- `ai-search.py`: unchanged (already had no direct Ollama HTTP calls after Phase 2)
- All 103 unit tests pass
- Zero remaining `requests.post()` calls, `OLLAMA_*_URL` constants, `import requests`, or `os.environ.get("OLLAMA_MODEL*")` reads outside `scripts/lib/`

---

## Phase 4 — Configuration file + gum TUI

**Goal:** Replace scattered env vars and hardcoded defaults with a single `~/.config/ai-scripts/config.toml`, plus an interactive `ai-config` command that queries Ollama for installed models and lets the user configure everything via gum.

### Config file

```toml
[models]
chat = "qwen3.5:9b"
embed = "qwen3-embedding:0.6b"
reasoning = "lfm2.5-thinking:1.2b"

[search]
top_k = 5
threshold = 0.8

[organize]
dupe_threshold = 0.12
hdbscan_min_cluster = 3
composite_alpha = 0.65
```

Precedence: env vars > config file > hardcoded defaults. Scripts that don't need the full config (e.g., `ai-cmd.sh`) just read `[models].chat`.

### New files

| File | Purpose |
|------|---------|
| `scripts/lib/config.py` | Python: `load_config()` → reads TOML, returns dict with defaults. Used by `ollama.py`. |
| `scripts/lib/config.sh` | Bash: `load_config_value SECTION KEY` → reads a single value via a tiny Python helper. Used by `common.sh`. |
| `scripts/ai-config.sh` | gum TUI: queries Ollama `/api/tags`, shows installed models, lets user pick chat/embed/reasoning, also configures search/organize thresholds. Writes TOML. |

### gum TUI flow (`ai-config`)

1. Ensure Ollama is running (via `ensure_ollama`)
2. Query `/api/tags` → get list of installed models
3. Show current config (or defaults if no config file)
4. `gum choose` for each model role:
   - Chat model (filter: all non-embedding models)
   - Embedding model (filter: models with "embed" in name, or all)
   - Reasoning model (filter: models with "thinking" in name, or all)
5. Optionally configure advanced settings (search top_k, thresholds, etc.)
6. Preview the TOML and confirm
7. Write to `~/.config/ai-scripts/config.toml`

### Integration into existing scripts

- **Python side:** `ollama.py` imports `load_config()` from `config.py` and uses its values as defaults (env vars still win via `os.environ.get(ENV, config_value)`).
- **Bash side:** `common.sh` gets a `load_model()` function that calls `config.sh` to read the configured model, falling back to env var → hardcoded default. Each bash script's `MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"` becomes `MODEL="${OLLAMA_MODEL:-$(load_config_value models chat "qwen3.5:9b")}"`.

### Rollout order

1. Create `scripts/lib/config.py` with `load_config()` and `CONFIG_PATH`
2. Create `scripts/lib/config.sh` with `load_config_value`
3. Update `ollama.py` to read model defaults from config
4. Update `common.sh` and bash scripts to read model defaults from config
5. Create `scripts/ai-config.sh` with gum TUI
6. Run tests to confirm no regressions

### Risk

Low. Additive — no existing behaviour changes unless a config file is present. Config file is optional; everything works without it using current defaults.

### Status: COMPLETE

Created the full configuration layer:
- `scripts/lib/config.py` (174 lines) — TOML config loader with `load_config()`, `get()`, `save_config()`, and a CLI helper mode. Includes a minimal TOML parser fallback for Python < 3.11 without tomli.
- `scripts/lib/config.sh` (20 lines) — bash bridge that calls config.py for single-value lookups.
- `scripts/ai-config.sh` (219 lines) — interactive gum TUI that:
  - Queries Ollama `/api/tags` for installed models with size/parameter info
  - Lets user pick chat, embedding, and reasoning models via `gum choose`
  - Optionally configures advanced settings (search top_k, thresholds)
  - Previews the TOML and saves on confirmation
  - Supports `--show`, `--path`, and `--reset` flags
- Updated `ollama.py` to read model defaults from config (with env-var override)
- Updated all 10 bash scripts to use `load_config_value` for model defaults
- Added `REASONING_MODEL` constant to `ollama.py` (was only hardcoded in ai-explain.sh)
- All 103 unit tests pass
- Precedence chain: env vars → config.toml → hardcoded defaults

---

## What NOT to consolidate

These are intentionally different per script and should stay where they are:

- **Prompt templates** — each script's system prompt is carefully tuned for its task
- **Temperature / num_predict / num_ctx** — intentionally different (0.1 for commands, 0.6 for explanations, 0.3 for RAG)
- **Action menus** — different choices per script (run/copy/edit vs stage/commit/regenerate)
- **Domain-specific logic** — HDBSCAN clustering, DuckDB schema inference, conventional-commit parsing, PR formatting
- **Injection defense preambles** — these are embedded in prompts and should stay close to where the untrusted data is injected (though wording could be standardised via a template function)

---

## Proposed file structure after consolidation

```
scripts/
├── lib/
│   ├── common.sh          # Bash: ollama lifecycle, clipboard, temp, think-strip, term-width
│   ├── config.sh           # Bash: bridge to config.py for single-value lookups
│   ├── config.py           # Python: TOML config loader with 3-tier precedence
│   ├── embeddings.py       # Python: DB schema, embedding, chunking, text extraction, indexing
│   └── ollama.py           # Python: thin Ollama API client (generate + embed)
├── ai-config.sh            # gum TUI: interactive model & settings configuration
├── ai-help.sh
├── data/
│   ├── ai-organize.sh
│   ├── ai-organize.py      # ~200 lines shorter; imports from lib/
│   ├── ai-duck.sh
│   └── test_ai_organize.py
├── gen/
│   ├── ai-cmd.sh           # ~40 lines shorter; sources lib/common.sh
│   ├── ai-explain.sh
│   ├── ai-narrative.sh
│   └── ai-slide-copy.sh
├── git/
│   ├── ai-commit.sh
│   └── ai-pr.sh
└── search/
    ├── ai-search.sh
    ├── ai-search.py         # ~250 lines shorter; imports from lib/
    ├── ai-chat.sh
    └── ai-chat.py           # ~100 lines shorter; imports from lib/
```

No changes to `Makefile`, `scripts.nix`, or any Nix wrappers. The `writeShellScriptBin` entries continue to `exec bash` into the same script paths. Python scripts continue to use `uv run` with inline deps.

---

## Estimated effort

| Phase | Scope | Effort | Risk |
|-------|-------|--------|------|
| Phase 1 — `common.sh` | 11 bash scripts | ~2 hours | Low |
| Phase 2 — `embeddings.py` | 3 Python scripts | ~3 hours | Medium |
| Phase 3 — `ollama.py` | 3 Python scripts | ~1 hour | Low |
| Phase 4 — Config file | All scripts | ~2 hours | Low |

Phases 1 and 2 are independent and can be done in parallel. Phase 3 depends on Phase 2 (or can be folded into it). Phase 4 is optional and can be deferred indefinitely.

---

## Verification strategy

1. **Phase 1:** After each script migration, run the command manually with the same inputs and confirm identical output. The action menus and gum UI should behave exactly the same.
2. **Phase 2:** After `embeddings.py` extraction:
   - `ai-search --index <dir>` → verify same chunk count and DB size
   - `ai-search "test query"` → verify same results and distances
   - `ai-chat "test question"` → verify same answer and sources
   - `ai-organize --scan <dir>` → verify same file list
   - `ai-organize --plan <dir> --dedupe` → verify same duplicate detection
   - `test_ai_organize.py` → all tests pass
3. **Phase 3:** Same verification as Phase 2 (the client is transparent).
4. **Regression guard:** Consider adding a small integration test that indexes a known directory, runs a search, and asserts expected results. This catches model-independent regressions in the DB/embedding pipeline.
