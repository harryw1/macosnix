#!/usr/bin/env bash
# git-ai-commit — use ollama to generate a conventional commit message
# Works standalone (make git) and as the backing script for the nix-installed
# `git-ai-commit` / `gaic` command.
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"
# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
git-ai-commit — generate conventional commit messages with Ollama

Usage:
  git-ai-commit          # interactive: review diff, pick action
  gaic                   # alias (same command)

Environment:
  OLLAMA_MODEL           Chat model (default: qwen3.5:9b)
HELP
  exit 0
fi

# ── Guard: must be inside a git repo ──────────────────────────────────────────
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo " Not inside a git repository."
  exit 1
fi

# ── Guard: must have something to commit ──────────────────────────────────────
STATUS=$(git status --short)
if [ -z "$STATUS" ]; then
  echo " Nothing to commit — working tree is clean."
  exit 0
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

# ── Gather git context (cap diff to avoid token overflow) ─────────────────────
DIFF=$(git diff HEAD 2>/dev/null | head -c 8000 || true)
[ -z "$DIFF" ] && DIFF=$(git diff --cached 2>/dev/null | head -c 8000 || true)

# ── Build prompt ───────────────────────────────────────────────────────────────
PROMPT_FILE=$(mktemp)
MSG_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE" "$MSG_FILE"' EXIT

printf '%s\n' \
  "You write conventional git commit messages. Given the git status and diff" \
  "below, output ONLY a single commit message — no preamble, no explanation," \
  "no markdown, no code fences." \
  "" \
  "Format: <type>(<optional scope>): <summary>" \
  "<blank line>" \
  "<optional body — only if the change genuinely needs explanation>" \
  "" \
  "Rules:" \
  "- Types: feat, fix, chore, docs, refactor, style, test, perf, ci, build" \
  "- Summary <= 72 chars, imperative mood (add / fix / update), no trailing period" \
  "- Omit body unless it adds real value" \
  "" \
  "--- git status ---" \
  "$STATUS" \
  "" \
  "--- diff (truncated at 8 kB) ---" \
  "$DIFF" \
  >"$PROMPT_FILE"

# ── Call ollama REST API ───────────────────────────────────────────────────────
# Using the API instead of `ollama run` lets us pass tuning parameters:
#   think: false      — disable chain-of-thought (qwen3 and similar); biggest speed win
#   temperature: 0.2  — deterministic output; commit messages aren't creative writing
#   num_predict: 200  — hard token cap; commits are short, no need to generate more
#   num_ctx: 4096     — enough for our truncated diff
PAYLOAD_FILE=$(mktemp)
export PROMPT_FILE MODEL PAYLOAD_FILE MSG_FILE
python3 -c "
import json, sys, os
with open(os.environ['PROMPT_FILE']) as f:
    prompt = f.read()
payload = {
    'model': os.environ['MODEL'],
    'prompt': prompt,
    'stream': False,
    'think': False,
    'options': {
        'temperature': 0.2,
        'num_predict': 200,
        'num_ctx': 4096,
    }
}
print(json.dumps(payload))
" >"$PAYLOAD_FILE"
trap 'rm -f "$PROMPT_FILE" "$MSG_FILE" "$PAYLOAD_FILE"' EXIT

export PROMPT_FILE MODEL PAYLOAD_FILE MSG_FILE
gum spin --title "󰚩  Generating commit message with $MODEL..." -- \
  sh -c 'curl -s http://localhost:11434/api/generate -H "Content-Type: application/json" -d @"$PAYLOAD_FILE" > "$MSG_FILE" 2>/dev/null'

# Parse response; fall back to awk anchor on commit type if model ignored think:false
RAW=$(python3 -c "
import json, os, sys
try:
    with open(os.environ['MSG_FILE']) as f:
        d = json.load(f)
    if 'error' in d:
        print('Ollama error: ' + d['error'], file=sys.stderr)
    print(d.get('response', ''))
except Exception as e:
    # Show the raw file content for debugging
    with open(os.environ['MSG_FILE']) as f:
        raw = f.read()[:200]
    print(f'Failed to parse Ollama response: {e}', file=sys.stderr)
    if raw:
        print(f'Raw response: {raw}', file=sys.stderr)
" 2>&1 || true)
COMMIT_MSG=$(printf '%s' "$RAW" |
  awk '
      /<think>/        { xml=1 }
      xml && /<\/think>/ { xml=0; next }
      xml              { next }
      !found && /^(feat|fix|chore|docs|refactor|style|test|perf|ci|build)(\([^)]*\))?!?:/ { found=1 }
      found            { print }
    ' |
  head -20 |
  sed '/^[[:space:]]*$/d' |
  sed 's/^[[:space:]]*//')

# If anchor didn't match (model returned clean output), use the whole response
if [ -z "$COMMIT_MSG" ]; then
  COMMIT_MSG=$(printf '%s' "$RAW" | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//')
fi

if [ -z "$COMMIT_MSG" ]; then
  echo " No message generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

# ── Display proposed message ───────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
echo ""
gum style \
  --width "$TERM_WIDTH" \
  --border double --padding "1 2" \
  "$COMMIT_MSG"
echo ""

# ── Action menu ────────────────────────────────────────────────────────────────
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "  Stage all & commit" \
  "󰐃  Commit staged only" \
  "󰏫  Edit then commit" \
  "󰑐  Regenerate" \
  "  Abort")

case "$ACTION" in
"  Stage all & commit")
  git add -A
  printf '%s\n' "$COMMIT_MSG" | git commit -F -
  echo ""
  gum style "  Committed!"
  git log --oneline -1
  ;;
"󰐃  Commit staged only")
  printf '%s\n' "$COMMIT_MSG" | git commit -F -
  echo ""
  gum style "  Committed (staged only)!"
  git log --oneline -1
  ;;
"󰏫  Edit then commit")
  TMPFILE=$(mktemp)
  printf '%s\n' "$COMMIT_MSG" >"$TMPFILE"
  "${EDITOR:-nvim}" "$TMPFILE"
  EDITED=$(cat "$TMPFILE")
  rm -f "$TMPFILE"
  if [ -n "$EDITED" ]; then
    STAGE=$(gum choose --header "How should files be staged?" "Stage all" "Staged only")
    [ "$STAGE" = "Stage all" ] && git add -A
    printf '%s\n' "$EDITED" | git commit -F -
    echo ""
    gum style "  Committed!"
    git log --oneline -1
  else
    echo "Aborted (empty message)."
  fi
  ;;
"󰑐  Regenerate")
  exec bash "${BASH_SOURCE[0]}"
  ;;
"  Abort")
  echo "Aborted."
  exit 0
  ;;
esac
