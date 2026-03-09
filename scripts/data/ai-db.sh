#!/usr/bin/env bash
# ai-db — Interactive TUI for managing the ai-search embeddings database
#
# Browse indexed files, inspect chunks, search, clean up orphans, vacuum,
# and view feedback/utility statistics — all through a gum-powered interface.
#
# Usage:
#   ai-db                  # launch interactive TUI
#   ai-db --status         # print status and exit
#   ai-db --orphans        # list orphaned entries and exit
#   ai-db --vacuum         # vacuum the database and exit
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/../lib}/common.sh"

PY_SCRIPT="${AI_DB_PY_PATH:-$SCRIPT_DIR/ai-db.py}"

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DB_PATH="$XDG_DATA_HOME/ai-search/vectors.db"

# ── Dependency check ────────────────────────────────────────────────────────
if ! command -v gum >/dev/null 2>&1; then
  echo "Error: gum is required.  Install: brew install gum" >&2
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  gum style --foreground 196 " No database found at $DB_PATH"
  gum style --foreground 245 "  Run: ai-search --index <directory>  to create one."
  exit 1
fi

# ── Non-interactive flags ───────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
ai-db — Interactive TUI for managing the ai-search embeddings database

Usage:
  ai-db                  Launch interactive database manager
  ai-db --status         Print database stats and exit
  ai-db --orphans        List orphaned entries and exit
  ai-db --vacuum         Vacuum the database and exit
  ai-db --stale          List stale (modified-on-disk) files

Manage indexed files, inspect chunks, search, clean up orphans, rebuild
the FTS index, and view learned utility scores.
HELP
  exit 0
fi

if [[ "${1:-}" == "--status" ]]; then
  python3 "$PY_SCRIPT" status | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  Database:  {d['db_path']}\")
print(f\"  Size:      {d['size_mb']} MB\")
print(f\"  Files:     {d['files_indexed']}\")
print(f\"  Chunks:    {d['total_chunks']}\")
print(f\"  FTS rows:  {d['fts_rows']}\")
if d.get('feedback_chunks'):
    print(f\"  Feedback:  {d['feedback_chunks']} learned chunks ({d['feedback_size_mb']} MB)\")
"
  exit 0
fi

if [[ "${1:-}" == "--orphans" ]]; then
  python3 "$PY_SCRIPT" orphans
  exit 0
fi

if [[ "${1:-}" == "--vacuum" ]]; then
  gum spin --title "Vacuuming database..." -- python3 "$PY_SCRIPT" vacuum
  gum style --foreground 212 " Database vacuumed."
  exit 0
fi

if [[ "${1:-}" == "--stale" ]]; then
  python3 "$PY_SCRIPT" stale
  exit 0
fi

# ── Helper: show status bar ──────────────────────────────────────────────────

show_status() {
  local status_json
  status_json=$(python3 "$PY_SCRIPT" status 2>&1) || {
    gum style --foreground 196 " Failed to query database status"
    gum style --foreground 245 "  Error: $status_json"
    return 1
  }

  local files chunks size fts
  files=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['files_indexed'])") || files="?"
  chunks=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_chunks'])") || chunks="?"
  size=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['size_mb'])") || size="?"
  fts=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['fts_rows'])") || fts="?"

  gum style --border rounded --padding "0 2" --border-foreground 212 \
    "󰚩 Embeddings Database" \
    "" \
    "  Files: $files    Chunks: $chunks    FTS: $fts    Size: ${size} MB"
}

# ── Helper: file type breakdown ──────────────────────────────────────────────

show_file_types() {
  local status_json
  status_json=$(python3 "$PY_SCRIPT" status 2>&1) || {
    gum style --foreground 196 "  Failed to load file type data."
    return 1
  }

  echo "$status_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
types = d.get('file_types', [])
if not types:
    print('  No files indexed.')
else:
    total_chunks = sum(t['chunks'] for t in types)
    for t in types:
        ext = t['ext']
        files = t['files']
        chunks = t['chunks']
        pct = (chunks / total_chunks * 100) if total_chunks else 0
        bar_len = int(pct / 3)
        bar = '█' * bar_len + '░' * (33 - bar_len)
        print(f'  {ext:8s}  {files:4d} files  {chunks:5d} chunks  {bar}  {pct:.0f}%')
"
}

# ── Helper: browse files with filter ─────────────────────────────────────────

browse_files() {
  local file_list
  file_list=$(python3 "$PY_SCRIPT" files 2>&1) || {
    gum style --foreground 196 "  Failed to list files: $file_list"
    return
  }

  if [ -z "$file_list" ]; then
    gum style --foreground 196 "  No files indexed."
    return
  fi

  local selected
  selected=$(echo "$file_list" | gum filter \
    --header "Search indexed files (type to filter):" \
    --placeholder "Type to search..." \
    --height 20 \
    --width 120)

  if [ -z "$selected" ]; then
    return
  fi

  # Extract filepath from the formatted line (after the timestamp)
  local filepath
  filepath=$(echo "$selected" | sed 's/^.*[0-9][0-9]:[0-9][0-9]  //')

  inspect_file "$filepath"
}

# ── Helper: inspect a single file's chunks ───────────────────────────────────

inspect_file() {
  local filepath="$1"
  local chunks_json
  chunks_json=$(python3 "$PY_SCRIPT" chunks "$filepath" 2>&1) || {
    gum style --foreground 196 "  Failed to load chunks for: $filepath"
    return
  }

  local num_chunks
  num_chunks=$(echo "$chunks_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  gum style --border rounded --padding "0 1" --border-foreground 39 \
    " $filepath" \
    "  $num_chunks chunk(s)"

  echo ""

  echo "$chunks_json" | python3 -c "
import json, sys
chunks = json.load(sys.stdin)
for i, c in enumerate(chunks, 1):
    rid = c['rowid']
    size = c['chunk_text_len']
    preview = c.get('chunk_text_preview', c['snippet'])[:200].replace('\n', ' ')
    print(f'  Chunk {i}  (rowid {rid}, {size} chars)')
    print(f'    {preview}')
    print()
"

  echo ""
  local action
  action=$(gum choose \
    --header "Action for $filepath:" \
    "← Back" \
    "Delete all chunks for this file" \
    "Copy filepath")

  case "$action" in
    "Delete all chunks for this file")
      if gum confirm "Delete all $num_chunks chunk(s) for this file?"; then
        local result
        result=$(python3 "$PY_SCRIPT" delete "$filepath" 2>/dev/null)
        gum style --foreground 212 "  Deleted: $result"
      fi
      ;;
    "Copy filepath")
      echo -n "$filepath" | clip_copy
      gum style --foreground 212 "  Copied to clipboard."
      ;;
    *) ;;
  esac
}

# ── Helper: semantic search ──────────────────────────────────────────────────

do_search() {
  ensure_ollama

  local query
  query=$(gum input \
    --header "Semantic search query:" \
    --placeholder "e.g., where are my zsh aliases defined?" \
    --width 80)

  if [ -z "$query" ]; then
    return
  fi

  echo ""
  gum spin --title "󰚩  Searching (hybrid BM25 + vector)..." -- \
    sh -c "python3 '$PY_SCRIPT' search '$query' > /tmp/ai-db-search-results.txt 2>/dev/null"

  local results
  results=$(cat /tmp/ai-db-search-results.txt)
  rm -f /tmp/ai-db-search-results.txt

  if [ -z "$results" ]; then
    gum style --foreground 196 "  No results found."
    return
  fi

  gum style --bold --foreground 39 "Search results for: $query"
  echo ""
  echo "$results"
  echo ""

  gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
}

# ── Helper: orphan management ────────────────────────────────────────────────

manage_orphans() {
  gum spin --title "Scanning for orphaned entries..." -- \
    sh -c "python3 '$PY_SCRIPT' orphans > /tmp/ai-db-orphans.txt 2>/dev/null"

  local orphans
  orphans=$(cat /tmp/ai-db-orphans.txt)
  rm -f /tmp/ai-db-orphans.txt

  gum style --bold --foreground 39 "Orphaned Entries"
  gum style --foreground 245 "(Files in database whose source no longer exists on disk)"
  echo ""
  echo "$orphans"
  echo ""

  # Check if there are actual orphans (not just "No orphans found.")
  if echo "$orphans" | grep -q "orphaned file"; then
    if gum confirm "Remove all orphaned entries from the database?"; then
      local result
      result=$(python3 "$PY_SCRIPT" delete-orphans 2>/dev/null)
      gum style --foreground 212 "  $result"
    fi
  fi
}

# ── Helper: stale file check ────────────────────────────────────────────────

check_stale() {
  gum spin --title "Checking for stale entries..." -- \
    sh -c "python3 '$PY_SCRIPT' stale > /tmp/ai-db-stale.txt 2>/dev/null"

  local stale
  stale=$(cat /tmp/ai-db-stale.txt)
  rm -f /tmp/ai-db-stale.txt

  gum style --bold --foreground 39 "Stale Entries"
  gum style --foreground 245 "(Files modified on disk since last indexed)"
  echo ""

  echo "$stale" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data:
    print('  All files are up to date.')
else:
    for d in data:
        print(f\"  {d['filepath']}\")
        print(f\"    indexed: {d['indexed']}  →  on disk: {d['on_disk']}\")
        print()
    print(f'  {len(data)} stale file(s). Re-index to update.')
"

  echo ""
  gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
}

# ── Helper: maintenance menu ─────────────────────────────────────────────────

maintenance_menu() {
  local action
  action=$(gum choose \
    --header "Database Maintenance:" \
    "← Back" \
    "Vacuum (compact + integrity check)" \
    "Rebuild FTS5 index" \
    "Clean orphaned entries" \
    "Check stale files")

  case "$action" in
    "Vacuum (compact + integrity check)")
      gum spin --title "Vacuuming..." -- python3 "$PY_SCRIPT" vacuum > /tmp/ai-db-vacuum.txt 2>/dev/null
      local result
      result=$(cat /tmp/ai-db-vacuum.txt)
      rm -f /tmp/ai-db-vacuum.txt
      echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  Integrity:  {d['integrity']}\")
print(f\"  Before:     {d['size_before_mb']} MB\")
print(f\"  After:      {d['size_after_mb']} MB\")
print(f\"  Saved:      {d['saved_kb']} KB\")
"
      ;;
    "Rebuild FTS5 index")
      gum spin --title "Rebuilding FTS5 index..." -- python3 "$PY_SCRIPT" fts-rebuild > /tmp/ai-db-fts.txt 2>/dev/null
      local fts_result
      fts_result=$(cat /tmp/ai-db-fts.txt)
      rm -f /tmp/ai-db-fts.txt
      echo "$fts_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if d.get('rebuilt'):
    print(f\"  FTS5 index rebuilt: {d['fts_rows']} rows\")
else:
    print(f\"  Error: {d.get('error', 'unknown')}\")
"
      ;;
    "Clean orphaned entries")
      manage_orphans
      ;;
    "Check stale files")
      check_stale
      ;;
    *) ;;
  esac
}

# ── Helper: analytics menu ───────────────────────────────────────────────────

analytics_menu() {
  local action
  action=$(gum choose \
    --header "Analytics:" \
    "← Back" \
    "File type breakdown" \
    "Top files by chunk count" \
    "Top chunks by learned utility")

  case "$action" in
    "File type breakdown")
      echo ""
      gum style --bold --foreground 39 "File Type Distribution"
      echo ""
      show_file_types
      echo ""
      gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
      ;;
    "Top files by chunk count")
      echo ""
      gum style --bold --foreground 39 "Top Files by Chunk Count"
      echo ""
      python3 "$PY_SCRIPT" top-files
      echo ""
      gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
      ;;
    "Top chunks by learned utility")
      echo ""
      gum style --bold --foreground 39 "Top Chunks by Utility (Feedback Learning)"
      echo ""
      python3 "$PY_SCRIPT" top-utility
      echo ""
      gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
      ;;
    *) ;;
  esac
}

# ── Main Loop ────────────────────────────────────────────────────────────────

main() {
  while true; do
    clear
    show_status || true
    echo ""

    local choice
    choice=$(gum choose \
      --header "What would you like to do?" \
      --cursor "▸ " \
      "Browse indexed files" \
      "Search embeddings" \
      "Analytics & insights" \
      "Database maintenance" \
      "Quit")

    echo ""

    case "$choice" in
      "Browse indexed files")
        browse_files
        ;;
      "Search embeddings")
        do_search
        ;;
      "Analytics & insights")
        analytics_menu
        ;;
      "Database maintenance")
        maintenance_menu
        ;;
      "Quit")
        gum style --foreground 245 "Bye!"
        exit 0
        ;;
    esac
  done
}

main
