#!/usr/bin/env bash
# ai-pr — use ollama to generate a GitHub PR description
# Works standalone (make pr) and as the backing script for the nix-installed
# `ai-pr` / `aipr` command.
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"

# ── Guard: must be inside a git repo ──────────────────────────────────────────
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "❌ Not inside a git repository."
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
  echo "❌ Could not determine base branch. Override with: AIPR_BASE=main aipr"
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
  echo "❌ Already on base branch ($BASE_BRANCH). Checkout a feature branch first."
  exit 1
fi

# ── Gather git context ─────────────────────────────────────────────────────────
COMMITS=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null || true)

if [ -z "$COMMITS" ]; then
  echo "❌ No commits found between $BASE_BRANCH and $CURRENT_BRANCH."
  exit 1
fi

DIFF=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null | head -c 12000 || true)

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
        'temperature': 0.2,
        'num_predict': 500,
        'num_ctx': 6144,
    }
}
print(json.dumps(payload))
" >"$PAYLOAD_FILE"

gum spin --spinner dot --title "🦙  Generating PR description with $MODEL..." -- \
  sh -c "curl -s http://localhost:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d @$PAYLOAD_FILE > $MSG_FILE 2>/dev/null"

RAW=$(python3 -c \
  "import json; d=json.load(open('$MSG_FILE')); print(d.get('response',''))" \
  2>/dev/null || true)

# Strip any <think>…</think> blocks the model might emit
PR_TEXT=$(printf '%s' "$RAW" | awk '
    /<think>/          { xml=1 }
    xml && /<\/think>/ { xml=0; next }
    xml                { next }
    { print }
  ')

if [ -z "$PR_TEXT" ]; then
  echo "❌ No description generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"
  exit 1
fi

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
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
if ! [[ "$TERM_WIDTH" =~ ^[0-9]+$ ]]; then
  TERM_WIDTH=80
fi
[ "$TERM_WIDTH" -gt 100 ] && TERM_WIDTH=100

gum style \
  --width "$TERM_WIDTH" \
  --border double --padding "1 2" \
  --border-foreground 212 --foreground 255 \
  "$(printf '📋  %s\n\n%s' "$PR_TITLE" "$PR_BODY")"
echo ""

# ── Action menu ────────────────────────────────────────────────────────────────
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "🚀  Push & open PR with gh" \
  "📋  Copy to clipboard" \
  "✏️  Edit then open PR" \
  "🔄  Regenerate" \
  "❌  Abort")

case "$ACTION" in
"🚀  Push & open PR with gh")
  git push -u origin "$CURRENT_BRANCH"
  gh pr create --title "$PR_TITLE" --body "$PR_BODY"
  ;;
"📋  Copy to clipboard")
  printf 'Title: %s\n\n%s\n' "$PR_TITLE" "$PR_BODY" | pbcopy
  gum style --foreground 212 "✅  Copied to clipboard!"
  ;;
"✏️  Edit then open PR")
  TMPFILE=$(mktemp)
  printf 'TITLE: %s\n\n%s\n' "$PR_TITLE" "$PR_BODY" >"$TMPFILE"
  "${EDITOR:-nvim}" "$TMPFILE"
  EDITED_TITLE=$(grep '^TITLE:' "$TMPFILE" | head -1 | sed 's/^TITLE:[[:space:]]*//')
  EDITED_BODY=$(grep -v '^TITLE:' "$TMPFILE" | sed '1{/^[[:space:]]*$/d}')
  rm -f "$TMPFILE"
  if [ -n "$EDITED_TITLE" ]; then
    git push -u origin "$CURRENT_BRANCH"
    gh pr create --title "$EDITED_TITLE" --body "$EDITED_BODY"
  else
    echo "Aborted (empty title)."
  fi
  ;;
"🔄  Regenerate")
  exec "$0"
  ;;
"❌  Abort")
  echo "Aborted."
  exit 0
  ;;
esac
