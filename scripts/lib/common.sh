#!/usr/bin/env bash
# common.sh — shared functions for the ai-* script suite
#
# Source this file at the top of any ai-* script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../lib/common.sh"   # adjust path as needed
#
# Provides:
#   ensure_ollama [model]       Start Ollama if needed; optionally verify a model is pulled
#   clip_copy                   Pipe stdin to the system clipboard (macOS/Linux)
#   ollama_generate             Build JSON payload, POST to Ollama, print response text
#   strip_think_blocks          Remove <think>…</think> from stdin
#   term_width                  Print usable terminal width (capped at 100)
#   make_tempfiles VAR1 VAR2…   Create temp files, assign to named variables, register cleanup
#   load_config_value S K [D]   Read a value from config.toml (via config.sh)

# ── Configuration ────────────────────────────────────────────────────────────

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${_COMMON_DIR}/config.sh"

# ── Ollama lifecycle ─────────────────────────────────────────────────────────

ensure_ollama() {
  # Usage: ensure_ollama              — just make sure it's running
  #        ensure_ollama "qwen3.5:9b" — also verify the model is pulled
  local model="${1:-}"

  if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "󰚩 Starting Ollama..."
    open -a Ollama
    echo -n "Waiting for Ollama"
    local _tries=0
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

  if [ -n "$model" ]; then
    if ! curl -s http://localhost:11434/api/tags | grep -q "\"$model\""; then
      echo " Model '$model' not found. Run: ollama pull $model"
      exit 1
    fi
  fi
}

# ── Portable clipboard ───────────────────────────────────────────────────────

clip_copy() {
  # Pipe stdin to the system clipboard.  Falls back gracefully.
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  else
    echo " No clipboard tool found (pbcopy, xclip, or wl-copy)." >&2
    return 1
  fi
}

# ── Ollama generate (prompt → response text) ─────────────────────────────────

ollama_generate() {
  # Usage: ollama_generate PROMPT_FILE MODEL [options...]
  #
  # Options (passed as --key value):
  #   --temperature  0.2     (default: 0.2)
  #   --num_predict  200     (default: 200)
  #   --num_ctx      4096    (default: 4096)
  #   --think        true    (default: false)
  #   --spinner      "text"  (default: "Generating with <model>...")
  #
  # Prints the raw response text to stdout.
  # Exits non-zero with a helpful message if the model isn't pulled.

  local prompt_file="$1"
  local model="$2"
  shift 2

  # Defaults
  local temperature=0.2
  local num_predict=200
  local num_ctx=4096
  local think=false
  local spinner=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --temperature) temperature="$2"; shift 2 ;;
      --num_predict) num_predict="$2"; shift 2 ;;
      --num_ctx)     num_ctx="$2";     shift 2 ;;
      --think)       think="$2";       shift 2 ;;
      --spinner)     spinner="$2";     shift 2 ;;
      *) echo "ollama_generate: unknown option $1" >&2; return 1 ;;
    esac
  done

  [ -z "$spinner" ] && spinner="󰚩  Generating with $model..."

  local payload_file msg_file
  payload_file=$(mktemp)
  msg_file=$(mktemp)
  # Append to existing trap rather than replacing it
  trap "rm -f '$payload_file' '$msg_file'; $(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")" EXIT

  # Build JSON payload via Python (handles escaping correctly)
  PROMPT_FILE="$prompt_file" MODEL="$model" \
  TEMPERATURE="$temperature" NUM_PREDICT="$num_predict" NUM_CTX="$num_ctx" THINK="$think" \
  python3 -c "
import json, os
with open(os.environ['PROMPT_FILE']) as f:
    prompt = f.read()
payload = {
    'model': os.environ['MODEL'],
    'prompt': prompt,
    'stream': False,
    'think': os.environ['THINK'].lower() == 'true',
    'options': {
        'temperature': float(os.environ['TEMPERATURE']),
        'num_predict': int(os.environ['NUM_PREDICT']),
        'num_ctx': int(os.environ['NUM_CTX']),
    }
}
print(json.dumps(payload))
" >"$payload_file"

  # Call Ollama under a gum spinner
  PAYLOAD_FILE="$payload_file" MSG_FILE="$msg_file" \
  gum spin --title "$spinner" -- \
    sh -c 'curl -s http://localhost:11434/api/generate \
      -H "Content-Type: application/json" \
      -d @"$PAYLOAD_FILE" > "$MSG_FILE" 2>/dev/null'

  # Parse response JSON → plain text
  local response
  response=$(MSG_FILE="$msg_file" python3 -c "
import json, os, sys
try:
    with open(os.environ['MSG_FILE']) as f:
        d = json.load(f)
    if 'error' in d:
        print('Ollama error: ' + d['error'], file=sys.stderr)
    print(d.get('response', ''))
except Exception as e:
    with open(os.environ['MSG_FILE']) as f:
        raw = f.read()[:200]
    print(f'Failed to parse Ollama response: {e}', file=sys.stderr)
    if raw:
        print(f'Raw response: {raw}', file=sys.stderr)
" 2>&1 || true)

  if [ -z "$response" ]; then
    echo " No response generated. Is '$model' pulled? Run: ollama pull $model" >&2
    return 1
  fi

  printf '%s' "$response"
}

# ── Think-block stripping ────────────────────────────────────────────────────

strip_think_blocks() {
  # Remove <think>…</think> blocks from stdin.  Reads stdin, writes stdout.
  awk '
    /<think>/          { xml=1 }
    xml && /<\/think>/ { xml=0; next }
    xml                { next }
    { print }
  '
}

# ── Pipeline post-processing (verify + feedback) ─────────────────────────────

pipeline_post() {
  # Usage: pipeline_post TOOL QUERY ANSWER
  #
  # Runs the post-generation pipeline (verification + feedback logging) and
  # prints the JSON result.  Returns non-zero only on hard failure.
  #
  # Requires: uv, python3, pipeline_post.py on AI_LIB_PATH.
  local tool="$1" query="$2" answer="$3"

  # Locate lib directory (Nix wrapper sets AI_LIB_PATH; fallback to co-located)
  local lib_dir="${AI_LIB_PATH:-$_COMMON_DIR}"
  local post_py="$lib_dir/pipeline_post.py"

  if [ ! -f "$post_py" ]; then
    echo '{"verified":true,"confidence":1.0,"issues":[],"exemplar":null}'
    return 0
  fi

  # Build JSON payload safely via python, then pipe to pipeline_post
  local json_payload
  json_payload=$(TOOL="$tool" QUERY="$query" ANSWER="$answer" python3 -c "
import json, os
print(json.dumps({
    'tool': os.environ['TOOL'],
    'query': os.environ['QUERY'],
    'answer': os.environ['ANSWER'],
}))
")

  printf '%s' "$json_payload" | uv run "$post_py" 2>/dev/null || \
    echo '{"verified":true,"confidence":1.0,"issues":[],"exemplar":null}'
}

# ── Terminal width ───────────────────────────────────────────────────────────

term_width() {
  # Print the usable terminal width, capped at 100 columns.
  local w
  w=$(tput cols 2>/dev/null || echo 80)
  if ! [[ "$w" =~ ^[0-9]+$ ]]; then w=80; fi
  [ "$w" -gt 100 ] && w=100
  echo "$w"
}

# ── Temp-file helper ─────────────────────────────────────────────────────────

make_tempfiles() {
  # Usage: make_tempfiles PROMPT_FILE MSG_FILE PAYLOAD_FILE
  # Creates a temp file for each argument and exports the variable.
  # Registers a single EXIT trap that cleans up all of them.
  local _cleanup_files=()
  for varname in "$@"; do
    local tmpf
    tmpf=$(mktemp)
    eval "$varname='$tmpf'"
    export "$varname"
    _cleanup_files+=("$tmpf")
  done

  # Build cleanup command
  local cleanup_cmd="rm -f ${_cleanup_files[*]}"
  # Append to any existing EXIT trap
  local existing_trap
  existing_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
  if [ -n "$existing_trap" ]; then
    trap "$existing_trap; $cleanup_cmd" EXIT
  else
    trap "$cleanup_cmd" EXIT
  fi
}
