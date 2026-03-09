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

MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"
EMBED_MODEL="${OLLAMA_MODEL_EMBED:-qwen3-embedding:0.6b}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PY_SCRIPT="${AI_ORGANIZE_PY_PATH:-$DIR/ai-organize.py}"

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
    --rename)     DO_RENAME=true;     FLAGS_GIVEN=true; shift ;;
    --organize)   DO_ORGANIZE=true;   FLAGS_GIVEN=true; shift ;;
    --flatten)    DO_FLATTEN=true;    FLAGS_GIVEN=true; shift ;;
    --dedupe)     DO_DEDUPE=true;     FLAGS_GIVEN=true; shift ;;
    --dry-run)    DO_DRY_RUN=true;    shift ;;
    --top-level)  DO_TOP_LEVEL=true;  shift ;;
    --all-files)  DO_ALL_FILES=true;  shift ;;
    --help|-h)
      echo "Usage: ai-organize [DIR] [--rename] [--organize] [--flatten] [--dedupe] [--dry-run] [--top-level] [--all-files]"
      echo ""
      echo "  --rename      Suggest more-descriptive filenames"
      echo "  --organize    Propose a logical folder structure"
      echo "  --flatten     Collapse nested paths into a flat layout"
      echo "  --dedupe      Flag files with near-identical content"
      echo "  --dry-run     Preview changes without applying them"
      echo "  --top-level   Scan only the top-level directory (non-recursive)"
      echo "  --all-files   Include source/config files (skipped by default in code projects)"
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

# ── Ensure Ollama is running ────────────────────────────────────────────────────
ensure_ollama() {
  if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "󰚩 Starting Ollama..."
    open -a Ollama
    echo -n "  Waiting for Ollama"
    while ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; do
      sleep 1
      echo -n "."
    done
    echo " ready!"
  fi

  if ! curl -s http://localhost:11434/api/tags | grep -q "\"$MODEL\""; then
    echo " Chat model '$MODEL' not found. Run: ollama pull $MODEL"
    exit 1
  fi
}

# ── Interactive prompts (only when not fully specified via flags) ───────────────
echo ""
gum style --foreground "#ca9ee6" --bold "󰉓  ai-organize"
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
  if echo "$CHOSEN" | grep -q "Rename";     then DO_RENAME=true;   fi
  if echo "$CHOSEN" | grep -q "Flatten";    then DO_FLATTEN=true;  fi
  if echo "$CHOSEN" | grep -q "duplicates"; then DO_DEDUPE=true;   fi
fi

# Final safety check
if ! $DO_RENAME && ! $DO_ORGANIZE && ! $DO_FLATTEN && ! $DO_DEDUPE; then
  echo "No operations selected. Exiting."
  exit 0
fi

# ── Assemble python flag list ──────────────────────────────────────────────────
PY_FLAGS=""
$DO_RENAME    && PY_FLAGS="$PY_FLAGS --rename"
$DO_ORGANIZE  && PY_FLAGS="$PY_FLAGS --organize"
$DO_FLATTEN   && PY_FLAGS="$PY_FLAGS --flatten"
$DO_DEDUPE    && PY_FLAGS="$PY_FLAGS --dedupe"
$DO_TOP_LEVEL && PY_FLAGS="$PY_FLAGS --top-level"
$DO_ALL_FILES && PY_FLAGS="$PY_FLAGS --all-files"

ensure_ollama

echo ""
gum style --bold "Analyzing: $TARGET_DIR"
echo ""

# ── Step 1: scan (fast — show spinner) ────────────────────────────────────────
SCAN_FILE=$(mktemp /tmp/ai-organize-scan-XXXXXX.json)
PLAN_FILE=$(mktemp /tmp/ai-organize-plan-XXXXXX.json)
trap 'rm -f "$SCAN_FILE" "$PLAN_FILE"' EXIT

# Scan flags: filtering options that affect which files are included
SCAN_FLAGS=""
$DO_TOP_LEVEL && SCAN_FLAGS="$SCAN_FLAGS --top-level"
$DO_ALL_FILES && SCAN_FLAGS="$SCAN_FLAGS --all-files"

gum spin --spinner dot --title "Scanning files…" -- \
  bash -c "uv run \"$PY_SCRIPT\" --scan \"$TARGET_DIR\" $SCAN_FLAGS > \"$SCAN_FILE\""

FILE_COUNT=$(python3 -c "import json; print(len(json.load(open('$SCAN_FILE'))))")
echo "  Found $FILE_COUNT file(s)."
echo ""

# ── Step 2: generate plan (slow — stream Python's progress to terminal) ────────
echo "󰚩  Generating plan… (this may take a minute)"
echo ""

OLLAMA_MODEL="$MODEL" OLLAMA_MODEL_EMBED="$EMBED_MODEL" \
  uv run "$PY_SCRIPT" --plan "$TARGET_DIR" --from-scan "$SCAN_FILE" $PY_FLAGS > "$PLAN_FILE"

echo ""

if [[ ! -s "$PLAN_FILE" ]]; then
  echo " Error: No plan was generated."
  exit 1
fi

# ── Display plan ───────────────────────────────────────────────────────────────
PLAN_FILE="$PLAN_FILE" python3 - <<'PYEOF'
import json, os, sys

plan_file = os.environ["PLAN_FILE"]
with open(plan_file) as f:
    plan = json.load(f)

ops     = plan.get("operations", [])
summary = plan.get("summary", "")

reset  = "\033[0m"
bold   = "\033[1m"
dim    = "\033[2m"
blue   = "\033[38;5;111m"
green  = "\033[38;5;114m"
yellow = "\033[38;5;221m"
pink   = "\033[38;5;213m"
gray   = "\033[38;5;244m"
red    = "\033[38;5;203m"

mkdirs  = [o for o in ops if o.get("op") == "mkdir"]
moves   = [o for o in ops if o.get("op") == "move"]
renames = [o for o in ops if o.get("op") == "rename"]
dupes   = [o for o in ops if o.get("op") == "duplicate"]

actionable = len(moves) + len(renames)
total      = actionable + len(dupes)

if total == 0:
    print(f"{yellow}No changes suggested.{reset}")
    sys.exit(0)

if summary:
    print(f"{bold}{blue}Summary:{reset} {summary}")
    print()

# ── Moves ──────────────────────────────────────────────────────────────────────
if moves:
    print(f"{bold}{green}  Moves  ({len(moves)}){reset}")
    for op in moves:
        reason = f"  {gray}← {op.get('reason','')}{reset}" if op.get("reason") else ""
        print(f"  {dim}from{reset}  {op['from']}")
        print(f"  {green}  to{reset}  {op['to']}{reason}")
        print()

# ── Renames ────────────────────────────────────────────────────────────────────
if renames:
    print(f"{bold}{yellow}  Renames  ({len(renames)}){reset}")
    for op in renames:
        reason = f"  {gray}← {op.get('reason','')}{reset}" if op.get("reason") else ""
        print(f"  {dim}{op['from']}{reset}  →  {yellow}{op['to']}{reset}{reason}")
    print()

# ── New folders ────────────────────────────────────────────────────────────────
if mkdirs:
    print(f"{bold}{blue}  New folders  ({len(mkdirs)}){reset}")
    for op in mkdirs:
        print(f"  {blue}  {op['path']}/{reset}")
    print()

# ── Duplicates ─────────────────────────────────────────────────────────────────
if dupes:
    print(f"{bold}{red}  Duplicate groups  ({len(dupes)}){reset}")
    for i, op in enumerate(dupes, 1):
        files_str = ", ".join(op.get("files", []))
        print(f"  {red}Group {i}:{reset} {files_str}")
        if op.get("reason"):
            print(f"  {gray}{op['reason']}{reset}")
        print()

print(f"{dim}─────────────────────────────────────────────────{reset}")
print(f"  {actionable} file operation(s)  ·  {len(dupes)} duplicate group(s)")

# ── Validation warnings ──────────────────────────────────────────────────
warnings = plan.get("warnings", [])
if warnings:
    print()
    print(f"{bold}{yellow}  Quality checks{reset}")
    for w in warnings:
        icon = f"{yellow}⚠{reset}" if w.get("level") == "warn" else f"{red}✗{reset}"
        print(f"  {icon} {w['msg']}")
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
    gum style --foreground "#a6d189" "No file moves or renames to apply."
    echo "  Duplicate groups above are informational — review and remove manually."
  else
    gum style --foreground "#e5c890" "No changes suggested for this directory."
  fi
  exit 0
fi

echo ""

# ── Dry-run path ───────────────────────────────────────────────────────────────
if $DO_DRY_RUN; then
  gum style --foreground "#e5c890" --bold "Dry run — no changes will be made:"
  echo ""
  uv run "$PY_SCRIPT" --apply "$PLAN_FILE" --dry-run
  echo ""
  gum style --foreground "#e5c890" "Run without --dry-run to apply."
  exit 0
fi

# ── Confirm and apply ──────────────────────────────────────────────────────────
if ! gum confirm "Apply these changes to $(basename "$TARGET_DIR")?"; then
  echo "Aborted. No changes made."
  exit 0
fi

echo ""
gum spin --spinner dot --title "Applying changes…" -- \
  bash -c "uv run \"$PY_SCRIPT\" --apply \"$PLAN_FILE\""

echo ""
gum style --foreground "#a6d189" --bold " Done!"

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
