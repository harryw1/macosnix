#!/usr/bin/env bash
# ai-cmd — turn a plain-English description into a shell command using Ollama
#
# Usage:
#   ai-cmd "show all git commits from the last 7 days"
#   ai-cmd "find all .nix files modified today"
#   echo "delete DS_Store files recursively" | ai-cmd
#   ai-cmd              # interactive prompt via gum
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"

# ── Gather input ───────────────────────────────────────────────────────────────
QUERY=""

if [[ $# -ge 1 ]]; then
  QUERY="$*"
fi

# Stdin (piped) overrides positional args
if ! [ -t 0 ]; then
  STDIN_DATA=$(cat)
  [ -n "$STDIN_DATA" ] && QUERY="$STDIN_DATA"
fi

# Fall back to interactive gum prompt
if [ -z "$QUERY" ]; then
  QUERY=$(gum input \
    --placeholder "Describe what you want to do…" \
    --width 60 \
    --header "󰆍  ai-cmd — describe a task")
  [ -z "$QUERY" ] && echo "Aborted." && exit 0
fi

# ── Ensure ollama is running ───────────────────────────────────────────────────
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

# ── Gather shell context ───────────────────────────────────────────────────────
OS_INFO="$(uname -s) $(uname -m)"
SHELL_NAME="$(basename "${SHELL:-zsh}")"
CWD="$PWD"
GIT_CTX=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] && GIT_CTX="- Git branch: $BRANCH"
fi

# ── Build prompt ───────────────────────────────────────────────────────────────
PROMPT_FILE=$(mktemp)
MSG_FILE=$(mktemp)
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE" "$MSG_FILE" "$PAYLOAD_FILE"' EXIT

printf '%s\n' \
  "You are a shell command expert. Generate a single shell command for the task described below." \
  "Output ONLY this line: COMMAND: <the command>" \
  "No explanation. No alternatives. No markdown. No code fences. Just the COMMAND: line." \
  "" \
  "Context:" \
  "- OS: $OS_INFO" \
  "- Shell: $SHELL_NAME" \
  "- Working directory: $CWD" \
  "$GIT_CTX" \
  "" \
  "Task: $QUERY" \
  >"$PROMPT_FILE"

export PROMPT_FILE MODEL PAYLOAD_FILE MSG_FILE
python3 -c "
import json, os
with open(os.environ['PROMPT_FILE']) as f:
    prompt = f.read()
payload = {
    'model': os.environ['MODEL'],
    'prompt': prompt,
    'stream': False,
    'think': False,
    'options': {
        'temperature': 0.1,
        'num_predict': 200,
        'num_ctx': 2048,
    }
}
print(json.dumps(payload))
" >"$PAYLOAD_FILE"

gum spin --spinner dot --title "󰚩  Generating command with $MODEL..." -- \
  sh -c 'curl -s http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d @"$1" > "$2" 2>/dev/null' _ "$PAYLOAD_FILE" "$MSG_FILE"

RAW=$(python3 -c \
  "import json, os; d=json.load(open(os.environ['MSG_FILE'])); print(d.get('response',''))" \
  2>/dev/null || true)

# Strip any <think>…</think> blocks the model might emit
CLEAN=$(printf '%s' "$RAW" | awk '
    /<think>/          { xml=1 }
    xml && /<\/think>/ { xml=0; next }
    xml                { next }
    { print }
  ')

# Extract the command from COMMAND: prefix, fallback to first non-blank line
CMD=$(printf '%s' "$CLEAN" | grep '^COMMAND:' | head -1 | sed 's/^COMMAND:[[:space:]]*//')
if [ -z "$CMD" ]; then
  CMD=$(printf '%s' "$CLEAN" | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^[[:space:]]*//')
fi

if [ -z "$CMD" ]; then
  echo " No command generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

# ── Display proposed command ───────────────────────────────────────────────────
echo ""
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
if ! [[ "$TERM_WIDTH" =~ ^[0-9]+$ ]]; then TERM_WIDTH=80; fi
[ "$TERM_WIDTH" -gt 100 ] && TERM_WIDTH=100

gum style \
  --width "$TERM_WIDTH" \
  --border double --padding "1 2" \
  "$(printf '󰆍  %s' "$CMD")"
echo ""

# ── Action menu ────────────────────────────────────────────────────────────────
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "  Run it" \
  "󰆏  Copy to clipboard" \
  "󰏫  Edit then run" \
  "󰑐  Regenerate" \
  "  Abort")

case "$ACTION" in
"  Run it")
  if gum confirm "$(printf 'Run: %s' "$CMD")"; then
    echo ""
    eval "$CMD"
  else
    echo "Cancelled."
  fi
  ;;
"󰆏  Copy to clipboard")
  printf '%s' "$CMD" | pbcopy
  gum style "  Copied to clipboard!"
  ;;
"󰏫  Edit then run")
  TMPFILE=$(mktemp)
  printf '%s\n' "$CMD" >"$TMPFILE"
  "${EDITOR:-nvim}" "$TMPFILE"
  EDITED=$(cat "$TMPFILE")
  rm -f "$TMPFILE"
  if [ -n "$EDITED" ]; then
    echo ""
    gum style \
      --width "$TERM_WIDTH" \
      --border rounded --padding "1 2" \
      "$(printf '󰆍  %s' "$EDITED")"
    echo ""
    if gum confirm "$(printf 'Run: %s' "$EDITED")"; then
      echo ""
      eval "$EDITED"
    else
      echo "Cancelled."
    fi
  else
    echo "Aborted (empty command)."
  fi
  ;;
"󰑐  Regenerate")
  exec bash "${BASH_SOURCE[0]}" "$QUERY"
  ;;
"  Abort")
  echo "Aborted."
  exit 0
  ;;
esac
