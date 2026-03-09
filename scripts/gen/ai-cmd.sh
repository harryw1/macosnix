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

# ── Describe command results via LLM ─────────────────────────────────────────
describe_result() {
  # Usage: describe_result "command" "output" exit_code
  local cmd="$1" output="$2" exit_code="$3"

  local desc_prompt
  desc_prompt=$(mktemp)
  trap "rm -f '$desc_prompt'; $(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")" EXIT

  local output_section
  if [ -z "$output" ] && [ "$exit_code" -eq 0 ]; then
    output_section="The command produced no output and exited successfully (exit code 0)."
  elif [ -z "$output" ]; then
    output_section="The command produced no output and exited with code $exit_code."
  else
    # Truncate very long output to keep prompt manageable
    local trimmed
    trimmed=$(printf '%s' "$output" | head -80)
    local total_lines
    total_lines=$(printf '%s' "$output" | wc -l | tr -d ' ')
    if [ "$total_lines" -gt 80 ]; then
      output_section="$(printf '%s\n(… %s total lines, showing first 80)' "$trimmed" "$total_lines")"
    else
      output_section="$trimmed"
    fi
    output_section="$(printf 'Exit code: %s\n\n%s' "$exit_code" "$output_section")"
  fi

  printf '%s\n' \
    "You are a concise shell assistant. A user ran a command and got the result below." \
    "Briefly describe what happened in 1–3 plain-English sentences." \
    "If the output is empty, explain what that likely means for this specific command." \
    "If there was an error, explain what went wrong." \
    "No markdown. No code fences. No preamble." \
    "" \
    "--- command ---" \
    "$cmd" \
    "" \
    "--- result ---" \
    "$output_section" \
    >"$desc_prompt"

  local desc_raw
  desc_raw=$(ollama_generate "$desc_prompt" "$MODEL" \
    --temperature 0.4 --num_predict 300 --num_ctx 2048 \
    --spinner "󰚩  Summarising results…")

  local desc
  desc=$(printf '%s' "$desc_raw" | strip_think_blocks)
  [ -z "$desc" ] && desc="$desc_raw"

  if [ -n "$desc" ]; then
    echo ""
    gum style \
      --width "$TERM_WIDTH" \
      --border rounded --padding "1 2" \
      --border-foreground 105 \
      "$(printf '󰋽  %s' "$desc")"
  fi
}

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
    run_output=$(eval "$CMD" 2>&1) && run_exit=$? || run_exit=$?
    # Show the raw output first (if any), so the user sees the real data
    [ -n "$run_output" ] && printf '%s\n' "$run_output"
    describe_result "$CMD" "$run_output" "$run_exit"
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
      edit_output=$(eval "$EDITED" 2>&1) && edit_exit=$? || edit_exit=$?
      [ -n "$edit_output" ] && printf '%s\n' "$edit_output"
      describe_result "$EDITED" "$edit_output" "$edit_exit"
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
