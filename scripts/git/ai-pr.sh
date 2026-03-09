#!/usr/bin/env bash
# ai-pr — use ollama to generate a GitHub PR description
# Works standalone (make pr) and as the backing script for the nix-installed
# `ai-pr` / `aipr` command.
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

MODEL="${OLLAMA_MODEL:-$(load_config_value models chat "qwen3.5:9b")}"
# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
ai-pr — generate a GitHub PR description from commits and diff using Ollama

Usage:
  ai-pr                  # run from a feature branch

Environment:
  OLLAMA_MODEL           Chat model (default: qwen3.5:9b)
  AIPR_BASE              Override base branch detection (e.g. AIPR_BASE=main ai-pr)
HELP
  exit 0
fi

# ── Guard: must be inside a git repo ──────────────────────────────────────────
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo " Not inside a git repository."
  exit 1
fi

# ── Resolve base branch ────────────────────────────────────────────────────────
# Priority: env override → remote HEAD → common name scan
BASE_BRANCH="${AIPR_BASE:-}"

if [ -z "$BASE_BRANCH" ] && git remote get-url origin >/dev/null 2>&1; then
  BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' || true)
fi

if [ -z "$BASE_BRANCH" ]; then
  for candidate in main master develop trunk; do
    if git show-ref --verify --quiet "refs/remotes/origin/$candidate" \
    || git show-ref --verify --quiet "refs/heads/$candidate"; then
      BASE_BRANCH="$candidate"
      break
    fi
  done
fi

if [ -z "$BASE_BRANCH" ]; then
  echo " Could not determine base branch. Override with: AIPR_BASE=main aipr"
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
  echo " Already on base branch ($BASE_BRANCH). Checkout a feature branch first."
  exit 1
fi

# ── Gather git context ─────────────────────────────────────────────────────────
COMMITS=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null || true)

if [ -z "$COMMITS" ]; then
  echo " No commits found between $BASE_BRANCH and $CURRENT_BRANCH."
  exit 1
fi

DIFF=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null | head -c 12000 || true)

# ── Ensure ollama is running ───────────────────────────────────────────────────
ensure_ollama

# ── Build prompt ───────────────────────────────────────────────────────────────
make_tempfiles PROMPT_FILE

printf '%s\n' \
  "You write concise, high-quality GitHub Pull Request descriptions." \
  "Given the commit list and diff below, output ONLY a PR description in this exact format:" \
  "" \
  "TITLE: <title under 70 chars, imperative mood>" \
  "" \
  "## Summary" \
  "<2–4 bullet points: what changed and why, referencing real file/function names>" \
  "" \
  "## Test plan" \
  "<2–4 checkbox items: how to verify the change works>" \
  "" \
  "Rules:" \
  "- No preamble, no explanation, no markdown code fences" \
  "- Title must start with a conventional type: feat/fix/chore/docs/refactor/style/test/perf/ci" \
  "- Be specific — name actual files, functions, or flags that changed" \
  "- Omit a section only if it genuinely has nothing to say" \
  "" \
  "--- branch: $CURRENT_BRANCH → $BASE_BRANCH ---" \
  "" \
  "--- commits ---" \
  "$COMMITS" \
  "" \
  "--- diff (truncated at 12 kB) ---" \
  "$DIFF" \
  >"$PROMPT_FILE"

RAW=$(ollama_generate "$PROMPT_FILE" "$MODEL" \
  --temperature 0.2 --num_predict 500 --num_ctx 6144 \
  --spinner "󰚩  Generating PR description with $MODEL...")

# Strip any <think>…</think> blocks the model might emit
PR_TEXT=$(printf '%s' "$RAW" | strip_think_blocks)

if [ -z "$PR_TEXT" ]; then
  echo " No description generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

# ── Pipeline post-processing (verify + feedback) ─────────────────────────────
POST_RESULT=$(pipeline_post "ai-pr" "$COMMITS" "$PR_TEXT")

# ── Parse title / body ─────────────────────────────────────────────────────────
PR_TITLE=$(printf '%s' "$PR_TEXT" | grep '^TITLE:' | head -1 | sed 's/^TITLE:[[:space:]]*//')
PR_BODY=$(printf '%s' "$PR_TEXT" | grep -v '^TITLE:' | sed '1{/^[[:space:]]*$/d}')

if [ -z "$PR_TITLE" ]; then
  # Model ignored the format — use first non-blank line as title, rest as body
  PR_TITLE=$(printf '%s' "$PR_TEXT" | sed '/^[[:space:]]*$/d' | head -1)
  PR_BODY=$(printf '%s'  "$PR_TEXT" | sed '/^[[:space:]]*$/d' | tail -n +2)
fi

# ── Display proposed description ──────────────────────────────────────────────
echo ""
TERM_WIDTH=$(term_width)

gum style \
  --width "$TERM_WIDTH" \
  --border double --padding "1 2" \
  "$(printf '󰆏  %s\n\n%s' "$PR_TITLE" "$PR_BODY")"
echo ""

# ── Action menu ────────────────────────────────────────────────────────────────
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "  Push & open PR with gh" \
  "󰆏  Copy to clipboard" \
  "󰏫  Edit then open PR" \
  "󰑐  Regenerate" \
  "  Abort")

case "$ACTION" in
"  Push & open PR with gh")
  if ! git push -u origin "$CURRENT_BRANCH"; then
    echo " Push failed. Check your remote configuration and try again."
    exit 1
  fi
  gh pr create --title "$PR_TITLE" --body "$PR_BODY"
  ;;
"󰆏  Copy to clipboard")
  printf 'Title: %s\n\n%s\n' "$PR_TITLE" "$PR_BODY" | clip_copy
  gum style "  Copied to clipboard!"
  ;;
"󰏫  Edit then open PR")
  TMPFILE=$(mktemp)
  printf 'TITLE: %s\n\n%s\n' "$PR_TITLE" "$PR_BODY" >"$TMPFILE"
  "${EDITOR:-nvim}" "$TMPFILE"
  EDITED_TITLE=$(grep '^TITLE:' "$TMPFILE" | head -1 | sed 's/^TITLE:[[:space:]]*//')
  EDITED_BODY=$(grep -v '^TITLE:' "$TMPFILE" | sed '1{/^[[:space:]]*$/d}')
  rm -f "$TMPFILE"
  if [ -n "$EDITED_TITLE" ]; then
    if ! git push -u origin "$CURRENT_BRANCH"; then
      echo " Push failed. Check your remote configuration and try again."
      exit 1
    fi
    gh pr create --title "$EDITED_TITLE" --body "$EDITED_BODY"
  else
    echo "Aborted (empty title)."
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
