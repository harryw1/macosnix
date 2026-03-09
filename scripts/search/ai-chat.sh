#!/usr/bin/env bash
# ai-chat — RAG chat over your indexed codebase, powered by Ollama
#
# Retrieves the most semantically relevant chunks from your ai-search vector
# store, injects them as context, and generates a grounded answer.
#
# Usage:
#   ai-chat "what font does my kitty config use?"
#   ai-chat "where are my zsh aliases defined?"
#   ai-chat              # interactive prompt via gum
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

EMBED_MODEL="${OLLAMA_MODEL_EMBED:-$(load_config_value models embed "qwen3-embedding:0.6b")}"
CHAT_MODEL="${OLLAMA_MODEL:-$(load_config_value models chat "qwen3.5:9b")}"
# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
ai-chat — RAG chat over your indexed codebase, powered by Ollama

Usage:
  ai-chat "what font does my kitty config use?"
  ai-chat "where are my zsh aliases defined?"
  ai-chat                # interactive prompt via gum

Requires: ai-search --index <dir> first to build the vector database.

Environment:
  OLLAMA_MODEL           Chat model (default: qwen3.5:9b)
  OLLAMA_MODEL_EMBED     Embedding model (default: qwen3-embedding:0.6b)
HELP
  exit 0
fi

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DB_PATH="$XDG_DATA_HOME/ai-search/vectors.db"

# Python script paths — overridden by Nix wrapper via env vars
PY_SCRIPT="${AI_CHAT_PY_PATH:-$SCRIPT_DIR/ai-chat.py}"
SEARCH_PY="${AI_SEARCH_PY_PATH:-$SCRIPT_DIR/ai-search.py}"

# ── Gather query ───────────────────────────────────────────────────────────────
QUERY=""

if [[ $# -ge 1 ]]; then
  QUERY="$*"
fi

# Fall back to interactive gum prompt
if [ -z "$QUERY" ]; then
  QUERY=$(gum input \
    --placeholder "Ask something about your codebase…" \
    --width 64 \
    --header "󰚩  ai-chat — ask your codebase")
  [ -z "$QUERY" ] && echo "Aborted." && exit 0
fi

# ── Ensure ollama is running ───────────────────────────────────────────────────
ensure_ollama

# ── Guard: database must exist ─────────────────────────────────────────────────
if [ ! -f "$DB_PATH" ]; then
  echo " No search database found. Index a directory first:"
  echo "  ai-search --index ~/path/to/your/repo"
  exit 1
fi

# ── Offer to index current directory if not yet indexed ───────────────────────
if [ -f "$SEARCH_PY" ]; then
  if ! uv run "$SEARCH_PY" --check-dir "$PWD" >/dev/null 2>&1; then
    echo ""
    if gum confirm "Current directory ($PWD) hasn't been indexed. Index it now?"; then
      echo ""
      uv run "$SEARCH_PY" --index "$PWD"
    fi
  fi
fi

# ── Determine search scope (git root > PWD) ────────────────────────────────────
SCOPE="$PWD"
if git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$GIT_ROOT" ] && SCOPE="$GIT_ROOT"
fi

# ── Run RAG pipeline ───────────────────────────────────────────────────────────
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT

export QUERY SCOPE RESULT_FILE PY_SCRIPT EMBED_MODEL CHAT_MODEL

gum spin --title "󰚩  Searching and generating with $CHAT_MODEL..." -- \
  sh -c 'OLLAMA_MODEL="$CHAT_MODEL" \
    OLLAMA_MODEL_EMBED="$EMBED_MODEL" \
    uv run "$PY_SCRIPT" --chat "$QUERY" --scope "$SCOPE" > "$RESULT_FILE" 2>/dev/null'

# ── Parse result ───────────────────────────────────────────────────────────────
ANSWER=$(python3 -c "
import json, os, sys
try:
    with open(os.environ['RESULT_FILE']) as f:
        d = json.load(f)
    if 'error' in d:
        print('Error: ' + d['error'], file=sys.stderr)
        sys.exit(1)
    print(d.get('answer', '').strip())
except Exception as e:
    print(f'Failed to parse response: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || true)

if [ -z "$ANSWER" ]; then
  echo " No answer generated."
  echo "  Is '$CHAT_MODEL' pulled?  Run: ollama pull $CHAT_MODEL"
  echo "  Is '$EMBED_MODEL' pulled? Run: ollama pull $EMBED_MODEL"
  exit 1
fi

# ── Low-confidence warning ─────────────────────────────────────────────────────
LOW_CONFIDENCE=$(python3 -c "
import json, os, sys
try:
    with open(os.environ['RESULT_FILE']) as f:
        d = json.load(f)
    sources = d.get('sources', [])
    if not sources:
        print('no_sources')
    elif len(sources) == 1 and sources[0].get('score', 0) < 0.6:
        print('weak')
except Exception:
    pass
" 2>/dev/null || true)

if [ "$LOW_CONFIDENCE" = "no_sources" ]; then
  gum style --foreground 214 \
    "⚠  No matching files found. Try re-indexing or asking a more specific question."
  echo ""
elif [ "$LOW_CONFIDENCE" = "weak" ]; then
  gum style --foreground 214 \
    "⚠  Low-confidence match — the answer below may not be accurate."
  echo ""
fi

# ── Display answer ─────────────────────────────────────────────────────────────
echo ""
TERM_WIDTH=$(term_width)

gum style \
  --width "$TERM_WIDTH" \
  --border rounded --padding "1 2" \
  "$ANSWER"
echo ""

# ── Display sources ────────────────────────────────────────────────────────────
python3 -c "
import json, os, sys

blue  = '\033[38;5;111m'
gray  = '\033[38;5;244m'
green = '\033[38;5;114m'
reset = '\033[0m'
bold  = '\033[1m'

try:
    with open(os.environ['RESULT_FILE']) as f:
        d = json.load(f)
    sources = d.get('sources', [])
    if not sources:
        sys.exit(0)
    print(f'{bold}Sources:{reset}')
    for i, s in enumerate(sources, 1):
        fp    = s['filepath']
        score = int(s['score'] * 100)
        # OSC 8 hyperlink — clickable in terminals that support it
        link = f'\033]8;;file://{fp}\033\\\\{fp}\033]8;;\033\\\\'
        print(f'  {blue}{i}. {link}{reset} {green}({score}% match){reset}')
    print()
except Exception:
    pass
" 2>/dev/null || true

# ── Action menu ────────────────────────────────────────────────────────────────
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "󰚩  Ask another question" \
  "󰆏  Copy answer to clipboard" \
  "  Abort")

case "$ACTION" in
"󰚩  Ask another question")
  exec bash "${BASH_SOURCE[0]}"
  ;;
"󰆏  Copy answer to clipboard")
  printf '%s' "$ANSWER" | clip_copy
  gum style "  Copied to clipboard!"
  ;;
"  Abort")
  echo "Aborted."
  exit 0
  ;;
esac
