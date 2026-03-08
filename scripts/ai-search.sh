#!/usr/bin/env bash
# ai-search — Semantic local search powered by Ollama and sqlite-vec
#
# Usage:
#   ai-search "where are my zsh aliases defined?"
#   ai-search --index ~/GitRepos/macosnix
#   ai-search --status
#   ai-search --clear
set -euo pipefail

MODEL="${OLLAMA_MODEL_EMBED:-qwen3-embedding:8b}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$XDG_DATA_HOME/ai-search"

# Python script path (can be overridden by Nix during build)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PY_SCRIPT="${AI_SEARCH_PY_PATH:-$DIR/ai-search.py}"

# Initialize variables
INDEX_DIR=""
DO_STATUS=false
DO_CLEAR=false
SEARCH_QUERY=""

# ── Parse arguments ────────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
  echo "Usage: ai-search <query>"
  echo "       ai-search --index <directory>"
  echo "       ai-search --status"
  echo "       ai-search --clear"
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --index|-i)
      if [ -z "${2:-}" ]; then
          echo "Error: --index requires a directory path."
          exit 1
      fi
      INDEX_DIR="$2"
      shift 2
      ;;
    --status|-s)
      DO_STATUS=true
      shift
      ;;
    --clear|-c)
      DO_CLEAR=true
      shift
      ;;
    -*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      if [ -z "$SEARCH_QUERY" ]; then
        SEARCH_QUERY="$1"
      else
        SEARCH_QUERY="$SEARCH_QUERY $1"
      fi
      shift
      ;;
  esac
done

# ── Ensure ollama is running ───────────────────────────────────────────────────
ensure_ollama() {
  if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "󰚩 Starting Ollama..."
    open -a Ollama
    echo -n "Waiting for Ollama"
    while ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; do
      sleep 1
      echo -n "."
    done
    echo " ready!"
  fi

  # Check if model is pulled
  if ! curl -s http://localhost:11434/api/tags | grep -q "\"$MODEL\""; then
      echo " Embedding model '$MODEL' not found. Run: ollama pull $MODEL"
      exit 1
  fi
}

# ── Handle Commands ────────────────────────────────────────────────────────────

if [ "$DO_CLEAR" = true ]; then
  gum confirm "Are you sure you want to delete the search database at $APP_DIR/vectors.db?" || exit 0
  uv run "$PY_SCRIPT" --clear
  exit 0
fi

if [ "$DO_STATUS" = true ]; then
  echo "󰆼 Database Status"
  uv run "$PY_SCRIPT" --status | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("  Path:     " + d["db_path"])
    print("  Size:     " + str(d["size_mb"]) + " MB")
    print("  Files:    " + str(d["files_indexed"]))
    print("  Chunks:   " + str(d["total_chunks"]))
except Exception as e:
    print("Error reading status.")
'
  exit 0
fi

if [ -n "$INDEX_DIR" ]; then
  ensure_ollama
  # Resolve to absolute path securely
  REAL_DIR=$(cd "$INDEX_DIR" 2>/dev/null && pwd || echo "$INDEX_DIR")
  
  if [ ! -d "$REAL_DIR" ]; then
      echo " Error: Directory '$REAL_DIR' does not exist."
      exit 1
  fi

  # Run indexing (Python writes directly to stderr for progress)
  uv run "$PY_SCRIPT" --index "$REAL_DIR"
  exit 0
fi

if [ -n "$SEARCH_QUERY" ]; then
  ensure_ollama
  
  # Ensure DB actually exists before searching
  if [ ! -f "$APP_DIR/vectors.db" ]; then
      echo " Error: No search database found. Please index a directory first:"
      echo "  ai-search --index ~/GitRepos"
      exit 1
  fi

  # Check if current directory has indexed files
  if ! uv run "$PY_SCRIPT" --check-dir "$PWD" >/dev/null 2>&1; then
      echo ""
      if gum confirm "The current directory ($PWD) hasn't been indexed. Do you want to index it now?"; then
          echo ""
          uv run "$PY_SCRIPT" --index "$PWD"
      fi
  fi

  RESULTS_FILE=$(mktemp)
  trap 'rm -f "$RESULTS_FILE"' EXIT
  export RESULTS_FILE
  
  gum spin --spinner dot --title "󰚩  Searching..." -- \
    sh -c 'uv run "$1" --search "$2" > "$3"' _ "$PY_SCRIPT" "$SEARCH_QUERY" "$RESULTS_FILE"

  # Check if empty (no results or error)
  if [ ! -s "$RESULTS_FILE" ]; then
      echo "No results found."
      exit 0
  fi
  
  # Format output beautifully using python to parse JSON and gum to style
  echo ""
  gum style --foreground "#ca9ee6" --bold "Top Semantic Matches:"
  echo ""

  python3 -c "
import json, sys, os
try:
    with open('$RESULTS_FILE') as f:
        results = json.load(f)
    if not results:
        print('No close matches found.')
        sys.exit(0)
    
    for i, r in enumerate(results, 1):
        filepath = r['filepath']
        snippet = r['snippet'].replace('\n', ' ')
        dist = r['distance']
        score = max(0, int((1.0 - dist) * 100)) # rough conversion to 0-100%
        
        # Color specific formatting using ANSI escape codes
        blue = '\033[38;5;111m'
        gray = '\033[38;5;244m'
        green = '\033[38;5;114m'
        reset = '\033[0m'
        bold = '\033[1m'
        
        # Format the file path to be clickable in many terminals
        file_link = f'\033]8;;file://{filepath}\033\\\\{filepath}\033]8;;\033\\\\'
        
        print(f'{bold}{blue}{i}. {file_link}{reset} {green}(Match: {score}%){reset}')
        print(f'   {gray}...{snippet}...{reset}')
        print()
except Exception as e:
    print('Failed to parse search results.', e)
"
  
  exit 0
fi
