#!/usr/bin/env bash
# ai-organize — AI-powered file reorganizer, renamer, and deduplicator.
#
# Usage:
#   ai-organize                             # Interactive: prompts for directory + operations
#   ai-organize ~/Downloads                 # Interactive for a specific directory
#   ai-organize ~/Downloads --organize      # Folder structure only
#   ai-organize ~/Downloads --rename        # Renames only
#   ai-organize ~/Downloads --flatten       # Flatten nested paths
#   ai-organize ~/Downloads --dedupe        # Flag duplicate files
#   ai-organize ~/Downloads --dry-run       # Preview plan, make no changes
#   ai-organize ~/Downloads --top-level     # Only consider files at root (non-recursive)
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/../lib}/common.sh"

MODEL="${OLLAMA_MODEL:-$(load_config_value models chat "qwen3.5:9b")}"
EMBED_MODEL="${OLLAMA_MODEL_EMBED:-$(load_config_value models embed "qwen3-embedding:0.6b")}"

PY_SCRIPT="${AI_ORGANIZE_PY_PATH:-$SCRIPT_DIR/ai-organize.py}"

# ── Parse arguments ────────────────────────────────────────────────────────────
TARGET_DIR=""
DO_RENAME=false
DO_ORGANIZE=false
DO_FLATTEN=false
DO_DEDUPE=false
DO_DRY_RUN=false
DO_TOP_LEVEL=false
DO_ALL_FILES=false
FLAGS_GIVEN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --rename)
    DO_RENAME=true
    FLAGS_GIVEN=true
    shift
    ;;
  --organize)
    DO_ORGANIZE=true
    FLAGS_GIVEN=true
    shift
    ;;
  --flatten)
    DO_FLATTEN=true
    FLAGS_GIVEN=true
    shift
    ;;
  --dedupe)
    DO_DEDUPE=true
    FLAGS_GIVEN=true
    shift
    ;;
  --dry-run)
    DO_DRY_RUN=true
    shift
    ;;
  --top-level)
    DO_TOP_LEVEL=true
    shift
    ;;
  --all-files)
    DO_ALL_FILES=true
    shift
    ;;
  --help | -h)
    echo "Usage: ai-organize [DIR] [--rename] [--organize] [--flatten] [--dedupe] [--dry-run] [--top-level] [--all-files]"
    echo ""
    echo "  --rename      Suggest more-descriptive filenames"
    echo "  --organize    Propose a logical folder structure"
    echo "  --flatten     Collapse nested paths into a flat layout"
    echo "  --dedupe      Flag files with near-identical content"
    echo "  --dry-run     Preview changes without applying them"
    echo "  --top-level   Scan only the top-level directory (non-recursive)"
    echo "  --all-files   Include source/config files (skipped by default in code projects)"
    echo ""
    echo "Environment:"
    echo "  OLLAMA_MODEL         Chat model (default: qwen3.5:9b)"
    echo "  OLLAMA_MODEL_EMBED   Embedding model (default: qwen3-embedding:0.6b)"
    exit 0
    ;;
  -*)
    echo "Unknown option: $1"
    exit 1
    ;;
  *)
    if [[ -z "$TARGET_DIR" ]]; then
      TARGET_DIR="$1"
    fi
    shift
    ;;
  esac
done

# ── Interactive prompts (only when not fully specified via flags) ───────────────
echo ""
gum style --bold --border rounded --padding "0 1" "󰉓  ai-organize"
echo ""

# 1. Target directory
if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR=$(gum input \
    --placeholder "Directory to organize (press Enter for current directory)" \
    --header "Target directory")
  TARGET_DIR="${TARGET_DIR:-$PWD}"
fi

# Resolve and validate
TARGET_DIR=$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")
if [[ ! -d "$TARGET_DIR" ]]; then
  echo " Error: Directory does not exist: $TARGET_DIR"
  exit 1
fi

# 2. Operations (interactive if none given via flags)
if ! $FLAGS_GIVEN; then
  echo ""
  gum style --faint "Directory: $TARGET_DIR"
  echo ""

  CHOSEN=$(gum choose --no-limit \
    --header "Select operations  (space to toggle, enter to confirm):" \
    "Reorganize into folders" \
    "Rename files" \
    "Flatten nested structure" \
    "Find duplicates") || true

  if [[ -z "$CHOSEN" ]]; then
    echo "No operations selected. Exiting."
    exit 0
  fi

  if echo "$CHOSEN" | grep -q "Reorganize"; then DO_ORGANIZE=true; fi
  if echo "$CHOSEN" | grep -q "Rename"; then DO_RENAME=true; fi
  if echo "$CHOSEN" | grep -q "Flatten"; then DO_FLATTEN=true; fi
  if echo "$CHOSEN" | grep -q "duplicates"; then DO_DEDUPE=true; fi
fi

# Final safety check
if ! $DO_RENAME && ! $DO_ORGANIZE && ! $DO_FLATTEN && ! $DO_DEDUPE; then
  echo "No operations selected. Exiting."
  exit 0
fi

# ── Assemble python flag list ──────────────────────────────────────────────────
PY_FLAGS=""
$DO_RENAME && PY_FLAGS="$PY_FLAGS --rename"
$DO_ORGANIZE && PY_FLAGS="$PY_FLAGS --organize"
$DO_FLATTEN && PY_FLAGS="$PY_FLAGS --flatten"
$DO_DEDUPE && PY_FLAGS="$PY_FLAGS --dedupe"
$DO_TOP_LEVEL && PY_FLAGS="$PY_FLAGS --top-level"
$DO_ALL_FILES && PY_FLAGS="$PY_FLAGS --all-files"

ensure_ollama "$MODEL"

echo ""
gum log --level info "Analyzing: $(basename "$TARGET_DIR")"
gum style --faint "$TARGET_DIR"
echo ""

# ── Step 1: scan (fast — show spinner) ────────────────────────────────────────
SCAN_FILE=$(mktemp /tmp/ai-organize-scan-XXXXXX.json)
PLAN_FILE=$(mktemp /tmp/ai-organize-plan-XXXXXX.json)
trap 'rm -f "$SCAN_FILE" "$PLAN_FILE"' EXIT

# Scan flags: filtering options that affect which files are included
SCAN_FLAGS=""
$DO_TOP_LEVEL && SCAN_FLAGS="$SCAN_FLAGS --top-level"
$DO_ALL_FILES && SCAN_FLAGS="$SCAN_FLAGS --all-files"

gum spin --title "Scanning files…" -- \
  bash -c "uv run \"$PY_SCRIPT\" --scan \"$TARGET_DIR\" $SCAN_FLAGS > \"$SCAN_FILE\""

FILE_COUNT=$(python3 -c "import json; print(len(json.load(open('$SCAN_FILE'))))")
echo "  Found $FILE_COUNT file(s)."
echo ""

# ── Step 2: generate plan (slow — stream Python's progress to terminal) ────────
echo "󰚩  Generating plan… (this may take a minute)"
echo ""

OLLAMA_MODEL="$MODEL" OLLAMA_MODEL_EMBED="$EMBED_MODEL" \
  uv run "$PY_SCRIPT" --plan "$TARGET_DIR" --from-scan "$SCAN_FILE" $PY_FLAGS >"$PLAN_FILE"

echo ""

if [[ ! -s "$PLAN_FILE" ]]; then
  echo " Error: No plan was generated."
  exit 1
fi

# ── Display plan ───────────────────────────────────────────────────────────────
PLAN_FILE="$PLAN_FILE" python3 - <<'PYEOF'
import json, os, sys
from pathlib import Path
from collections import defaultdict

plan_file = os.environ["PLAN_FILE"]
with open(plan_file) as f:
    plan = json.load(f)

ops     = plan.get("operations", [])
summary = plan.get("summary", "")

# ── Catppuccin Macchiato palette ──────────────────────────────────────────────
R   = "\033[0m"       # reset
B   = "\033[1m"       # bold
D   = "\033[2m"       # dim
lav = "\033[38;5;183m"  # lavender — headers
grn = "\033[38;5;114m"  # green — moves/success
ylw = "\033[38;5;221m"  # yellow — renames/warnings
mau = "\033[38;5;213m"  # mauve — accents
gry = "\033[38;5;244m"  # gray — secondary text
red = "\033[38;5;203m"  # red — errors/dupes
blu = "\033[38;5;111m"  # blue — folders
tl  = "\033[38;5;243m"  # tree lines (dim gray)

# ── Box-drawing characters ────────────────────────────────────────────────────
H  = "─"   # horizontal
TL = "╭"   # top-left
TR = "╮"   # top-right
BL = "╰"   # bottom-left
BR = "╯"   # bottom-right
V  = "│"   # vertical

mkdirs  = [o for o in ops if o.get("op") == "mkdir"]
moves   = [o for o in ops if o.get("op") == "move"]
renames = [o for o in ops if o.get("op") == "rename"]
dupes   = [o for o in ops if o.get("op") == "duplicate"]

actionable = len(moves) + len(renames)
total      = actionable + len(dupes)

if total == 0:
    print(f"  {ylw}No changes suggested.{R}")
    sys.exit(0)

# ── Summary bar ───────────────────────────────────────────────────────────────
if summary:
    print(f"  {B}{lav}{summary}{R}")
    print()

# ── Proposed folder structure (tree view) ──────────────────────────────────────
if mkdirs:
    # Build a tree from mkdir paths
    tree: dict = {}
    for op in mkdirs:
        parts = op["path"].split("/")
        node = tree
        for part in parts:
            node = node.setdefault(part, {})

    def print_tree(node, prefix="  ", is_last_map=None):
        if is_last_map is None:
            is_last_map = []
        items = sorted(node.keys())
        for i, name in enumerate(items):
            is_last = (i == len(items) - 1)
            # Build the connector
            if not is_last_map:
                connector = ""
            elif is_last:
                connector = f"{tl}{BL}{H}{R} "
            else:
                connector = f"{tl}{V}{R}  " if False else f"{tl}├{H}{R} "
            # Build the continuation prefix for children
            indent = ""
            for was_last in is_last_map:
                indent += f"    " if was_last else f" {tl}{V}{R}  "
            print(f"  {indent}{connector}{blu}{B}{name}/{R}")
            # Recurse into children
            print_tree(node[name], prefix, is_last_map + [is_last])

    print(f"  {B}{blu}Folder structure{R}")
    print_tree(tree)
    print()

# ── Moves (grouped by destination folder) ─────────────────────────────────────
if moves:
    print(f"  {B}{grn}Moves{R}  {gry}({len(moves)} files){R}")
    print()

    # Group moves by destination folder
    by_folder: dict[str, list[dict]] = defaultdict(list)
    for op in moves:
        folder = str(Path(op["to"]).parent)
        by_folder[folder].append(op)

    MAX_SHOW = 6  # max files to show per folder before collapsing

    for folder in sorted(by_folder.keys()):
        folder_ops = by_folder[folder]
        print(f"    {blu}{folder}/{R}  {gry}({len(folder_ops)} files){R}")

        show = folder_ops[:MAX_SHOW]
        for op in show:
            src_name = Path(op["from"]).name
            dst_name = Path(op["to"]).name
            src_dir  = str(Path(op["from"]).parent)
            # Show the source origin in gray
            if src_name == dst_name:
                print(f"      {grn}←{R} {D}{src_dir}/{R}{src_name}")
            else:
                print(f"      {grn}←{R} {D}{op['from']}{R}  →  {grn}{dst_name}{R}")

        remaining = len(folder_ops) - MAX_SHOW
        if remaining > 0:
            print(f"      {gry}… and {remaining} more{R}")
        print()

# ── Renames ────────────────────────────────────────────────────────────────────
if renames:
    print(f"  {B}{ylw}Renames{R}  {gry}({len(renames)} files){R}")
    print()
    for op in renames:
        src_dir  = str(Path(op["from"]).parent)
        src_name = Path(op["from"]).name
        dst_name = Path(op["to"]).name
        reason   = f"  {gry}← {op['reason']}{R}" if op.get("reason") else ""
        prefix   = f"{D}{src_dir}/{R}" if src_dir != "." else ""
        print(f"    {prefix}{D}{src_name}{R}  →  {ylw}{dst_name}{R}{reason}")
    print()

# ── Duplicates ─────────────────────────────────────────────────────────────────
if dupes:
    print(f"  {B}{red}Duplicates{R}  {gry}({len(dupes)} groups){R}")
    print()
    for i, op in enumerate(dupes, 1):
        files = op.get("files", [])
        # Show as a compact list with the common directory factored out
        dirs = {str(Path(f).parent) for f in files}
        if len(dirs) == 1:
            common_dir = dirs.pop()
            names = [Path(f).name for f in files]
            if common_dir != ".":
                print(f"    {red}{i}.{R} {D}{common_dir}/{R}{', '.join(names)}")
            else:
                print(f"    {red}{i}.{R} {', '.join(names)}")
        else:
            print(f"    {red}{i}.{R} {', '.join(files)}")
        if op.get("reason"):
            print(f"       {gry}{op['reason']}{R}")
    print()

# ── Footer ─────────────────────────────────────────────────────────────────────
bar = f"{gry}{H * 52}{R}"
print(bar)

parts = []
if moves:
    parts.append(f"{grn}{len(moves)}{R} move{'s' if len(moves) != 1 else ''}")
if renames:
    parts.append(f"{ylw}{len(renames)}{R} rename{'s' if len(renames) != 1 else ''}")
if dupes:
    parts.append(f"{red}{len(dupes)}{R} duplicate group{'s' if len(dupes) != 1 else ''}")

print(f"  {' · '.join(parts)}")

# ── Validation warnings ──────────────────────────────────────────────────
warnings = plan.get("warnings", [])
if warnings:
    print()
    print(f"  {B}{ylw}Quality checks{R}")
    for w in warnings:
        icon = f"{ylw}⚠{R}" if w.get("level") == "warn" else f"{red}✗{R}"
        print(f"  {icon} {w['msg']}")

# Footer check marks
if not warnings:
    print(f"  {grn}✓{R} {gry}No quality issues{R}")
PYEOF

# ── Determine if there's anything to apply ─────────────────────────────────────
HAS_ACTIONS=$(PLAN_FILE="$PLAN_FILE" python3 -c "
import json, os
with open(os.environ['PLAN_FILE']) as f:
    plan = json.load(f)
ops = plan.get('operations', [])
print('yes' if any(o.get('op') in ('mkdir','move','rename') for o in ops) else 'no')
")

if [[ "$HAS_ACTIONS" == "no" ]]; then
  echo ""
  if $DO_DEDUPE; then
    gum log --level info "No file moves or renames to apply."
    echo "  Duplicate groups above are informational — review and remove manually."
  else
    gum log --level warn "No changes suggested for this directory."
  fi
  exit 0
fi

echo ""

# ── Dry-run path ───────────────────────────────────────────────────────────────
if $DO_DRY_RUN; then
  gum log --level warn "Dry run — no changes will be made:"
  echo ""
  uv run "$PY_SCRIPT" --apply "$PLAN_FILE" --dry-run
  echo ""
  gum log --level info "Run without --dry-run to apply."
  exit 0
fi

# ── Confirm and apply ──────────────────────────────────────────────────────────
if ! gum confirm "Apply these changes to $(basename "$TARGET_DIR")?" \
  --affirmative "Yes, apply" --negative "No, cancel"; then
  echo "Aborted. No changes made."
  exit 0
fi

echo ""
gum spin --title "Applying changes…" -- \
  bash -c "uv run \"$PY_SCRIPT\" --apply \"$PLAN_FILE\""

echo ""
gum style --bold --border rounded --padding "0 1" "Done!"

DUPE_COUNT=$(PLAN_FILE="$PLAN_FILE" python3 -c "
import json, os
with open(os.environ['PLAN_FILE']) as f:
    plan = json.load(f)
print(sum(1 for o in plan.get('operations',[]) if o.get('op') == 'duplicate'))
")

if [[ "$DUPE_COUNT" -gt 0 ]]; then
  echo ""
  echo "  Note: $DUPE_COUNT duplicate group(s) flagged above — review and remove manually."
fi
