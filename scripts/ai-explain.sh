#!/usr/bin/env bash
# ai-explain — use ollama to explain a shell command or error in plain English
#
# Usage:
#   aiexplain "git rebase -i HEAD~3"        # explain a command
#   aiexplain "permission denied: /etc/hosts" # explain an error
#   some-cmd 2>&1 | aiexplain               # pipe output/error directly
#   aiexplain "cargo build" "error[E0382]…" # cmd + its output as two args
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"

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
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "🦙 Starting Ollama..."
  open -a Ollama
  echo -n "Waiting for Ollama"
  while ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; do
    sleep 1
    echo -n "."
  done
  echo " ready!"
fi

# ── Build prompt ───────────────────────────────────────────────────────────────
PROMPT_FILE=$(mktemp)
MSG_FILE=$(mktemp)
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE" "$MSG_FILE" "$PAYLOAD_FILE"' EXIT

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

python3 -c "
import json
with open('$PROMPT_FILE') as f:
    prompt = f.read()
payload = {
    'model': '$MODEL',
    'prompt': prompt,
    'stream': False,
    'think': False,
    'options': {
        'temperature': 0.3,
        'num_predict': 300,
        'num_ctx': 4096,
    }
}
print(json.dumps(payload))
" >"$PAYLOAD_FILE"

gum spin --spinner dot --title "🦙  Thinking with $MODEL..." -- \
  sh -c "curl -s http://localhost:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d @$PAYLOAD_FILE > $MSG_FILE 2>/dev/null"

RAW=$(python3 -c \
  "import json; d=json.load(open('$MSG_FILE')); print(d.get('response',''))" \
  2>/dev/null || true)

# Strip any <think>…</think> blocks
EXPLANATION=$(printf '%s' "$RAW" | awk '
    /<think>/          { xml=1 }
    xml && /<\/think>/ { xml=0; next }
    xml                { next }
    { print }
  ' | sed 's/^[[:space:]]*//')

if [ -z "$EXPLANATION" ]; then
  echo "❌ No explanation generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

echo ""
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
if ! [[ "$TERM_WIDTH" =~ ^[0-9]+$ ]]; then
  TERM_WIDTH=80
fi
[ "$TERM_WIDTH" -gt 100 ] && TERM_WIDTH=100

gum style \
  --width "$TERM_WIDTH" \
  --border rounded --padding "1 2" \
  --border-foreground 39 --foreground 255 \
  "$EXPLANATION"
echo ""
