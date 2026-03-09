#!/usr/bin/env bash
# ai-explain — use ollama to explain a shell command or error in plain English
#
# Usage:
#   aiexplain "git rebase -i HEAD~3"        # explain a command
#   aiexplain "permission denied: /etc/hosts" # explain an error
#   some-cmd 2>&1 | aiexplain               # pipe output/error directly
#   aiexplain "cargo build" "error[E0382]…" # cmd + its output as two args
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

MODEL="${OLLAMA_MODEL:-$(load_config_value models reasoning "lfm2.5-thinking:1.2b")}"
# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
ai-explain — explain a shell command or error in plain English using Ollama

Usage:
  ai-explain "git rebase -i HEAD~3"          # explain a command
  ai-explain "permission denied: /etc/hosts"  # explain an error
  some-cmd 2>&1 | ai-explain                  # pipe output/error directly
  ai-explain "cargo build" "error[E0382]…"   # cmd + its output as two args

Environment:
  OLLAMA_MODEL           Chat model (default: lfm2.5-thinking:1.2b)
HELP
  exit 0
fi

# ── Gather input ───────────────────────────────────────────────────────────────
CMD_INPUT=""
OUTPUT_INPUT=""

# Two positional args → first is the command, second is its output/error
if [[ $# -ge 2 ]]; then
  CMD_INPUT="$1"
  OUTPUT_INPUT="$2"
elif [[ $# -eq 1 ]]; then
  CMD_INPUT="$1"
fi

# Stdin (piped) supplements or replaces positional args
if ! [ -t 0 ]; then
  STDIN_DATA=$(cat)
  if [ -n "$CMD_INPUT" ]; then
    # arg = command label, stdin = its output
    OUTPUT_INPUT="$STDIN_DATA"
  else
    CMD_INPUT="$STDIN_DATA"
  fi
fi

if [ -z "$CMD_INPUT" ]; then
  echo "Usage: aiexplain <command or error text>"
  echo "       some-command 2>&1 | aiexplain"
  echo "       aiexplain \"<command>\" \"<its output>\""
  exit 1
fi

# ── Ensure ollama is running ───────────────────────────────────────────────────
ensure_ollama

# ── Build prompt ───────────────────────────────────────────────────────────────
make_tempfiles PROMPT_FILE

if [ -n "$OUTPUT_INPUT" ]; then
  # We have both a command and its output — focus on diagnosing the failure
  printf '%s\n' \
    "You are a friendly, concise shell expert." \
    "A command was run and produced the output below." \
    "Explain what went wrong in plain English and suggest the most likely fix." \
    "Keep your response to 6–10 lines max. No preamble. No markdown headers or code fences." \
    "" \
    "--- command ---" \
    "$CMD_INPUT" \
    "" \
    "--- output / error ---" \
    "$OUTPUT_INPUT" \
    >"$PROMPT_FILE"
else
  # Single input — detect whether it looks like an error or a command to explain
  printf '%s\n' \
    "You are a friendly, concise shell expert. Given the text below:" \
    "- If it looks like a shell command or pipeline: explain what each part does in plain English." \
    "- If it looks like an error message: explain what went wrong and suggest the most likely fix." \
    "Keep your response to 6–10 lines max. No preamble. No markdown headers or code fences." \
    "" \
    "--- input ---" \
    "$CMD_INPUT" \
    >"$PROMPT_FILE"
fi

# ── Generate and display ──────────────────────────────────────────────────────
RAW=$(ollama_generate "$PROMPT_FILE" "$MODEL" \
  --temperature 0.6 --num_predict 1500 --num_ctx 4096 \
  --spinner "󰚩  Thinking with $MODEL...")

EXPLANATION=$(printf '%s' "$RAW" | strip_think_blocks)
# If stripping removed everything, fall back to the raw response
[ -z "$EXPLANATION" ] && EXPLANATION="$RAW"

if [ -z "$EXPLANATION" ]; then
  echo " No explanation generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

# ── Pipeline post-processing (verify + feedback) ─────────────────────────────
POST_RESULT=$(pipeline_post "ai-explain" "$CMD_INPUT" "$EXPLANATION")
POST_VERIFIED=$(printf '%s' "$POST_RESULT" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('true' if d.get('verified', True) else 'false')
" 2>/dev/null || echo "true")

echo ""
TERM_WIDTH=$(term_width)

gum style \
  --width "$TERM_WIDTH" \
  --border rounded --padding "1 2" \
  "$EXPLANATION"

if [ "$POST_VERIFIED" = "false" ]; then
  gum style --foreground 214 \
    "⚠  Verification: some claims could not be fully verified."
fi
echo ""
