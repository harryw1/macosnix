#!/usr/bin/env bash
# ai-explain — use ollama to explain a shell command or error in plain English
#
# Usage:
#   aiexplain "git rebase -i HEAD~3"        # explain a command
#   aiexplain "permission denied: /etc/hosts" # explain an error
#   some-cmd 2>&1 | aiexplain               # pipe output/error directly
#   aiexplain "cargo build" "error[E0382]…" # cmd + its output as two args
set -euo pipefail

MODEL="${OLLAMA_MODEL:-lfm2.5-thinking:1.2b}"
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
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "󰚩 Starting Ollama..."
  open -a Ollama
  echo -n "Waiting for Ollama"
  _tries=0
  while ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; do
    sleep 1
    echo -n "."
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 30 ]; then
      echo ""
      echo " Ollama failed to start after 30 s. Is the app installed?"
      exit 1
    fi
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

export PROMPT_FILE MODEL PAYLOAD_FILE MSG_FILE
python3 -c "
import json, os
with open(os.environ['PROMPT_FILE']) as f:
    prompt = f.read()
payload = {
    'model': os.environ['MODEL'],
    'prompt': prompt,
    'stream': False,
    'options': {
        'temperature': 0.6,
        'num_predict': 1500,
        'num_ctx': 4096,
    }
}
print(json.dumps(payload))
" >"$PAYLOAD_FILE"

export PROMPT_FILE MODEL PAYLOAD_FILE MSG_FILE
gum spin --title "󰚩  Thinking with $MODEL..." -- \
  sh -c 'curl -s http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d @"$PAYLOAD_FILE" > "$MSG_FILE" 2>/dev/null'

# Cleanly parse out the think block and the final explanation using Python
EXPLANATION=$(python3 -c "
import json, os, re, sys
try:
    with open(os.environ['MSG_FILE']) as f:
        d = json.load(f)
    resp = d.get('response', '')
    cleaned = re.sub(r'<think>.*?</think>', '', resp, flags=re.DOTALL).strip()
    if not cleaned:
        cleaned = resp.strip()
    print(cleaned)
except Exception as e:
    print(f'Error parsing response: {e}')
    sys.exit(1)
" 2>&1 || true)

if [ -z "$EXPLANATION" ]; then
  echo " No explanation generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
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
  "$EXPLANATION"
echo ""
