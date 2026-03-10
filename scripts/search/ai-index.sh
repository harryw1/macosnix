#!/usr/bin/env bash
# ai-index — Quick index / reindex of the current directory
#
# A convenience wrapper around ai-search --index that focuses on the
# most common workflow: keeping the current working directory indexed.
#
# Usage:
#   ai-index              # index $PWD (interactive — shows status, confirms)
#   ai-index <directory>  # index a specific directory
#   ai-index --reindex    # force reindex $PWD (clear + index)
#   ai-index --status     # show index status for $PWD
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/../lib}/common.sh"

MODEL="${OLLAMA_MODEL_EMBED:-$(load_config_value models embed "qwen3-embedding:0.6b")}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$XDG_DATA_HOME/ai-search"
DB_PATH="$APP_DIR/vectors.db"

# Python backend (same as ai-search)
PY_SCRIPT="${AI_SEARCH_PY_PATH:-$SCRIPT_DIR/ai-search.py}"

# ── Parse arguments ──────────────────────────────────────────────────────────
TARGET_DIR=""
DO_REINDEX=false
DO_STATUS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --reindex|-r)
      DO_REINDEX=true
      shift
      ;;
    --status|-s)
      DO_STATUS=true
      shift
      ;;
    --help|-h)
      cat <<'HELP'
ai-index — Quick index / reindex of the current directory

Usage:
  ai-index              Index the current directory (incremental)
  ai-index <directory>  Index a specific directory
  ai-index --reindex    Force full reindex of current directory
  ai-index --status     Show index status for current directory

Flags:
  -r, --reindex    Clear existing chunks for this directory, then re-index
  -s, --status     Show how many files/chunks are indexed for $PWD
  -h, --help       Show this help

This is a convenience wrapper around ai-search --index that focuses on
the most common workflow: keeping your current project indexed for
ai-search and ai-chat.
HELP
      exit 0
      ;;
    -*)
      echo "Unknown option: $1 (try --help)" >&2
      exit 1
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

# Default to current directory
TARGET_DIR="${TARGET_DIR:-$PWD}"
REAL_DIR=$(cd "$TARGET_DIR" 2>/dev/null && pwd) || {
  gum style --foreground 196 " Directory not found: $TARGET_DIR"
  exit 1
}

# ── Status mode ──────────────────────────────────────────────────────────────
if [ "$DO_STATUS" = true ]; then
  if [ ! -f "$DB_PATH" ]; then
    show_empty "No search database found. Run: ai-index"
    exit 0
  fi

  gum style --bold --foreground 212 "󰆼 Index Status"
  gum style --foreground 245 "  Directory: $REAL_DIR"
  echo ""

  # Count files and chunks for this directory
  python3 -c "
import sqlite3, sys, os

db_path = '$DB_PATH'
prefix = '$REAL_DIR/'

conn = sqlite3.connect(db_path)
cur = conn.cursor()

cur.execute('SELECT COUNT(DISTINCT filepath), COUNT(*) FROM file_metadata WHERE filepath LIKE ?', (prefix + '%',))
files, chunks = cur.fetchone()

if files == 0:
    print('  Not indexed yet. Run: ai-index')
else:
    # Check for stale files
    cur.execute('SELECT filepath, mtime FROM file_metadata WHERE filepath LIKE ?', (prefix + '%',))
    rows = cur.fetchall()
    stale = 0
    missing = 0
    seen_files = set()
    for fp, mtime in rows:
        if fp in seen_files:
            continue
        seen_files.add(fp)
        if not os.path.exists(fp):
            missing += 1
        elif os.path.getmtime(fp) > mtime:
            stale += 1

    print(f'  Files:    {files}')
    print(f'  Chunks:   {chunks}')
    if stale > 0:
        print(f'  Stale:    {stale} (modified since last index)')
    if missing > 0:
        print(f'  Orphaned: {missing} (no longer on disk)')
    if stale == 0 and missing == 0:
        print(f'  Status:   ✓ Up to date')

conn.close()
"
  exit 0
fi

# ── Reindex mode ─────────────────────────────────────────────────────────────
if [ "$DO_REINDEX" = true ]; then
  if [ -f "$DB_PATH" ]; then
    # Count existing chunks for this directory
    existing=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$DB_PATH')
cur = conn.cursor()
cur.execute('SELECT COUNT(*) FROM file_metadata WHERE filepath LIKE ?', ('$REAL_DIR/%',))
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null || echo "0")

    if [ "$existing" -gt 0 ]; then
      gum style --foreground 214 "⚠  $existing existing chunk(s) for this directory will be removed first."
      echo ""
      if ! gum confirm "Reindex $REAL_DIR from scratch?"; then
        gum style --foreground 245 "  Cancelled."
        exit 0
      fi

      # Delete existing chunks for this directory only
      gum spin --title "Clearing old index for $REAL_DIR..." -- \
        python3 -c "
import sqlite3
conn = sqlite3.connect('$DB_PATH')
cur = conn.cursor()
cur.execute('SELECT rowid FROM file_metadata WHERE filepath LIKE ?', ('$REAL_DIR/%',))
rowids = [r[0] for r in cur.fetchall()]
if rowids:
    ph = ','.join('?' * len(rowids))
    cur.execute(f'DELETE FROM file_embeddings WHERE rowid IN ({ph})', rowids)
    cur.execute(f'DELETE FROM file_metadata WHERE rowid IN ({ph})', rowids)
conn.commit()
conn.close()
"
      gum style --foreground 212 "  Old index cleared."
      echo ""
    fi
  fi
fi

# ── Index ────────────────────────────────────────────────────────────────────
ensure_ollama "$MODEL"

echo ""
gum style --bold --foreground 212 "󰚩 Indexing"
gum style --foreground 245 "  Directory: $REAL_DIR"
gum style --foreground 245 "  Model:     $MODEL"
echo ""

# Show a quick summary of what we'll index
file_count=$(find "$REAL_DIR" \
  -not -path '*/.git/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/__pycache__/*' \
  -not -path '*/.venv/*' \
  -not -path '*/vendor/*' \
  -not -path '*/dist/*' \
  -not -path '*/build/*' \
  -type f \( \
    -name '*.sh' -o -name '*.py' -o -name '*.nix' -o -name '*.md' -o \
    -name '*.toml' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' -o \
    -name '*.txt' -o -name '*.rs' -o -name '*.go' -o -name '*.js' -o \
    -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.css' -o \
    -name '*.html' -o -name '*.csv' -o -name '*.bash' -o -name '*.zsh' -o \
    -name '*.pdf' -o -name '*.docx' -o -name '*.xlsx' \
  \) 2>/dev/null | wc -l | tr -d ' ')

gum style --foreground 245 "  Scannable files: ~$file_count"
echo ""

# Run the actual indexing via the shared Python backend
uv run "$PY_SCRIPT" --index "$REAL_DIR"

# Show post-index status
echo ""
if [ -f "$DB_PATH" ]; then
  total_chunks=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$DB_PATH')
cur = conn.cursor()
cur.execute('SELECT COUNT(DISTINCT filepath), COUNT(*) FROM file_metadata WHERE filepath LIKE ?', ('$REAL_DIR/%',))
files, chunks = cur.fetchone()
print(f'{files} files, {chunks} chunks')
conn.close()
" 2>/dev/null || echo "unknown")
  gum style --foreground 212 "  Index total: $total_chunks"
fi

echo ""
gum style --foreground 245 "  Tip: run 'ai search' or 'ai chat' to query your indexed files."
