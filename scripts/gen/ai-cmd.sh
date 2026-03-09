#!/usr/bin/env bash
# ai-cmd — turn a plain-English description into a shell command using Ollama
#
# Usage:
#   ai-cmd "show all git commits from the last 7 days"
#   ai-cmd "find all .nix files modified today"
#   echo "delete DS_Store files recursively" | ai-cmd
#   ai-cmd              # interactive prompt via gum
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/../lib}/common.sh"

MODEL="${OLLAMA_MODEL:-$(load_config_value models chat "qwen3.5:9b")}"
# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
ai-cmd — turn a plain-English description into a shell command using Ollama

Usage:
  ai-cmd "show all git commits from the last 7 days"
  ai-cmd "find all .nix files modified today"
  echo "delete DS_Store files recursively" | ai-cmd
  ai-cmd                 # interactive prompt via gum

Environment:
  OLLAMA_MODEL           Chat model (default: qwen3.5:9b)
HELP
  exit 0
fi

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
ensure_ollama

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
make_tempfiles PROMPT_FILE

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

RAW=$(ollama_generate "$PROMPT_FILE" "$MODEL" \
  --temperature 0.1 --num_predict 200 --num_ctx 2048 \
  --spinner "󰚩  Generating command with $MODEL...")

# Strip any <think>…</think> blocks the model might emit
CLEAN=$(printf '%s' "$RAW" | strip_think_blocks)

# Extract the command from COMMAND: prefix, fallback to first non-blank line
CMD=$(printf '%s' "$CLEAN" | grep '^COMMAND:' | head -1 | sed 's/^COMMAND:[[:space:]]*//')
if [ -z "$CMD" ]; then
  CMD=$(printf '%s' "$CLEAN" | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^[[:space:]]*//')
fi

if [ -z "$CMD" ]; then
  echo " No command generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

# ── Pipeline post-processing (verify + feedback) ─────────────────────────────
POST_RESULT=$(pipeline_post "ai-cmd" "$QUERY" "$CMD")
POST_VERIFIED=$(printf '%s' "$POST_RESULT" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('true' if d.get('verified', True) else 'false')
" 2>/dev/null || echo "true")

# ── Display proposed command ───────────────────────────────────────────────────
echo ""
TERM_WIDTH=$(term_width)

gum style \
  --width "$TERM_WIDTH" \
  --border double --padding "1 2" \
  "$(printf '󰆍  %s' "$CMD")"

if [ "$POST_VERIFIED" = "false" ]; then
  gum style --foreground 214 \
    "⚠  Verification: some claims could not be fully verified."
fi
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
  if gum confirm "$(printf 'Run: %s' "$CMD")" \
    --affirmative "Run it" --negative "Cancel"; then
    echo ""
    eval "$CMD"
  else
    echo "Cancelled."
  fi
  ;;
"󰆏  Copy to clipboard")
  printf '%s' "$CMD" | clip_copy
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
    if gum confirm "$(printf 'Run: %s' "$EDITED")" \
      --affirmative "Run it" --negative "Cancel"; then
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
