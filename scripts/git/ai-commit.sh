#!/usr/bin/env bash
# git-ai-commit — use ollama to generate a conventional commit message
# Works standalone (make git) and as the backing script for the nix-installed
# `git-ai-commit` / `gaic` command.
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/../lib}/common.sh"

MODEL="${OLLAMA_MODEL:-$(load_config_value models chat "qwen3.5:9b")}"
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
  echo " Not inside a git repository."
  exit 1
fi

# ── Guard: must have something to commit ──────────────────────────────────────
STATUS=$(git status --short)
if [ -z "$STATUS" ]; then
  echo " Nothing to commit — working tree is clean."
  exit 0
fi

# ── Ensure ollama is running ───────────────────────────────────────────────────
ensure_ollama

# ── Gather git context (cap diff to avoid token overflow) ─────────────────────
DIFF=$(git diff HEAD 2>/dev/null | head -c 8000 || true)
[ -z "$DIFF" ] && DIFF=$(git diff --cached 2>/dev/null | head -c 8000 || true)

# ── Build prompt ───────────────────────────────────────────────────────────────
make_tempfiles PROMPT_FILE

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
# temperature 0.2: low creativity for consistent conventional commits
# num_predict 200: commit messages are short; num_ctx 4096: room for diff context
RAW=$(ollama_generate "$PROMPT_FILE" "$MODEL" \
  --temperature 0.2 --num_predict 200 --num_ctx 4096 \
  --spinner "󰚩  Generating commit message with $MODEL...")

# Parse response; fall back to awk anchor on commit type if model ignored think:false
COMMIT_MSG=$(printf '%s' "$RAW" |
  strip_think_blocks |
  awk '
      !found && /^(feat|fix|chore|docs|refactor|style|test|perf|ci|build)(\([^)]*\))?!?:/ { found=1 }
      found            { print }
    ' |
  head -20 |
  sed '/^[[:space:]]*$/d' |
  sed 's/^[[:space:]]*//')

# If anchor didn't match (model returned clean output), use the whole response
if [ -z "$COMMIT_MSG" ]; then
  COMMIT_MSG=$(printf '%s' "$RAW" | strip_think_blocks | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//')
fi

if [ -z "$COMMIT_MSG" ]; then
  echo " No message generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

# Verify commit message format and log for feedback learning
POST_RESULT=$(pipeline_post "ai-commit" "$STATUS" "$COMMIT_MSG")

# ── Display proposed message ───────────────────────────────────────────────────
TERM_WIDTH=$(term_width)
echo ""
gum style \
  --width "$TERM_WIDTH" \
  --border double --padding "1 2" \
  "$COMMIT_MSG"
echo ""

# ── Action menu ────────────────────────────────────────────────────────────────
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "  Stage all & commit" \
  "󰐃  Commit staged only" \
  "󰏫  Edit then commit" \
  "󰑐  Regenerate" \
  "  Abort") || { echo "Aborted."; exit 0; }

case "$ACTION" in
"  Stage all & commit")
  git add -A
  printf '%s\n' "$COMMIT_MSG" | git commit -F -
  echo ""
  gum style "  Committed!"
  git log --oneline -1
  ;;
"󰐃  Commit staged only")
  printf '%s\n' "$COMMIT_MSG" | git commit -F -
  echo ""
  gum style "  Committed (staged only)!"
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
    gum style "  Committed!"
    git log --oneline -1
  else
    echo "Aborted (empty message)."
  fi
  ;;
"󰑐  Regenerate")
  exec bash "${BASH_SOURCE[0]}"
  ;;
"  Abort")
  echo "Aborted."
  exit 0
  ;;
esac
