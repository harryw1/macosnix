#!/usr/bin/env bash
# ai — unified launcher for the ai-* CLI suite
#
# A single gum-powered TUI that dispatches to every tool in the suite.
# Replaces the need to remember a dozen aliases.
#
# Usage:
#   ai                     # launch interactive menu
#   ai <tool> [args...]    # bypass menu, run a tool directly
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/lib}/common.sh"

# ── Dependency check ────────────────────────────────────────────────────────
if ! command -v gum >/dev/null 2>&1; then
  echo "Error: gum is required.  Install: brew install gum" >&2
  exit 1
fi

# ── Tool registry ───────────────────────────────────────────────────────────
# Format: "display label|command|description"
# Grouped by category; headers are entries with command=":"

TOOLS=(
  # ── Git ──
  "  git-ai-commit    Generate commit messages|git-ai-commit|AI-powered conventional commits from staged changes"
  "  ai-pr            Generate PR descriptions|ai-pr|Draft a GitHub PR title and body from branch diff"

  # ── Generate ──
  "  ai-cmd           Natural language → shell|ai-cmd|Describe what you want, get a shell command"
  "  ai-explain       Explain commands / errors|ai-explain|Paste a command or error for a plain-English explanation"
  "  ai-narrative     Data → report prose|ai-narrative|Turn metrics and data into written narrative"
  "  ai-slide-copy    Data → slide content|ai-slide-copy|Turn metrics and data into slide-ready copy"

  # ── Data ──
  "  ai-duck          Query data files (DuckDB)|ai-duck|Ask natural-language questions about CSV / Parquet / JSON"
  "  ai-organize      Reorganize & deduplicate|ai-organize|AI-powered file renaming, grouping, and dedup"

  # ── Search & Chat ──
  "  ai-search        Semantic local search|ai-search|Index a directory and search by meaning"
  "  ai-chat          RAG chat over codebase|ai-chat|Chat with your indexed files using retrieval-augmented generation"

  # ── Database ──
  "  ai-db            Manage embeddings DB|ai-db|Browse, inspect, vacuum, and maintain the vector database"

  # ── Setup ──
  "  ai-config        Configure models|ai-config|Pick Ollama models and tune thresholds"
  "  ollama-pull      Pull required models|ollama-pull|Download all default Ollama models"
  "  pyinit           Scaffold Python project|pyinit|Interactive Python project scaffolding with uv"
  "  report-init      Scaffold report project|report-init|Scaffold a research / analysis / report directory"
)

# ── Direct dispatch (bypass menu) ───────────────────────────────────────────
if [[ $# -gt 0 ]]; then
  subcmd="$1"; shift

  # Allow short names like "cmd" → "ai-cmd", "search" → "ai-search", etc.
  case "$subcmd" in
    commit)    exec git-ai-commit "$@" ;;
    pr)        exec ai-pr "$@" ;;
    cmd)       exec ai-cmd "$@" ;;
    explain)   exec ai-explain "$@" ;;
    narrative) exec ai-narrative "$@" ;;
    slides)    exec ai-slide-copy "$@" ;;
    duck)      exec ai-duck "$@" ;;
    organize)  exec ai-organize "$@" ;;
    search)    exec ai-search "$@" ;;
    chat)      exec ai-chat "$@" ;;
    db)        exec ai-db "$@" ;;
    config)    exec ai-config "$@" ;;
    pull)      exec ollama-pull "$@" ;;
    help)
      echo "ai — unified launcher for the AI CLI suite"
      echo ""
      echo "Usage:"
      echo "  ai                     Interactive tool picker"
      echo "  ai <tool> [args...]    Run a tool directly"
      echo ""
      echo "Short names:"
      echo "  commit    git-ai-commit      pr        ai-pr"
      echo "  cmd       ai-cmd             explain   ai-explain"
      echo "  narrative ai-narrative       slides    ai-slide-copy"
      echo "  duck      ai-duck            organize  ai-organize"
      echo "  search    ai-search          chat      ai-chat"
      echo "  db        ai-db              config    ai-config"
      echo "  pull      ollama-pull"
      echo ""
      echo "Examples:"
      echo "  ai cmd 'list large files'    Run ai-cmd directly"
      echo "  ai search --index .          Index current directory"
      echo "  ai db --status               Show database stats"
      exit 0
      ;;
    *)
      # Try as a full command name
      if command -v "$subcmd" >/dev/null 2>&1; then
        exec "$subcmd" "$@"
      elif command -v "ai-$subcmd" >/dev/null 2>&1; then
        exec "ai-$subcmd" "$@"
      else
        echo "Unknown tool: $subcmd" >&2
        echo "Run 'ai help' for available tools." >&2
        exit 1
      fi
      ;;
  esac
fi

# ── Interactive menu ────────────────────────────────────────────────────────

# Build display labels for gum
labels=()
for entry in "${TOOLS[@]}"; do
  label="${entry%%|*}"
  labels+=("$label")
done

clear
gum style --bold --foreground 212 --margin "1 0 0 0" \
  "󰚩 AI Toolkit"
gum style --foreground 245 --margin "0 0 1 0" \
  "  Select a tool, or run 'ai <tool>' directly"

choice=$(printf '%s\n' "${labels[@]}" | gum choose \
  --cursor "▸ " \
  --height 20) || exit 0

# Look up the command for the selected label
cmd=""
desc=""
for entry in "${TOOLS[@]}"; do
  label="${entry%%|*}"
  if [[ "$label" == "$choice" ]]; then
    rest="${entry#*|}"
    cmd="${rest%%|*}"
    desc="${rest#*|}"
    break
  fi
done

if [[ -z "$cmd" ]]; then
  exit 0
fi

echo ""
gum style --foreground 245 "  $desc"
echo ""

# Tools that have their own TUI — launch directly
case "$cmd" in
  ai-db|ai-config|ai-organize|ai-search|ai-chat)
    exec "$cmd"
    ;;
esac

# Tools that need input — prompt for it
case "$cmd" in
  git-ai-commit)
    # Just run it — it reads the git diff itself
    exec git-ai-commit
    ;;

  ai-pr)
    exec ai-pr
    ;;

  ai-cmd)
    input=$(gum input \
      --header "Describe the command you need:" \
      --placeholder "e.g., find files larger than 100MB" \
      --width 80) || exit 0
    [[ -z "$input" ]] && exit 0
    exec ai-cmd "$input"
    ;;

  ai-explain)
    input=$(gum input \
      --header "Paste a command or error to explain:" \
      --placeholder "e.g., tar -xzf archive.tar.gz" \
      --width 80) || exit 0
    [[ -z "$input" ]] && exit 0
    exec ai-explain "$input"
    ;;

  ai-narrative|ai-slide-copy)
    input=$(gum write \
      --header "Paste data or metrics (Ctrl+D to finish):" \
      --placeholder "Paste CSV, bullet points, or raw numbers..." \
      --width 80 \
      --height 10) || exit 0
    [[ -z "$input" ]] && exit 0
    echo "$input" | exec "$cmd"
    ;;

  ai-duck)
    # Need a file and a question
    file=$(gum file --height 10) || exit 0
    [[ -z "$file" ]] && exit 0
    question=$(gum input \
      --header "Question about $file:" \
      --placeholder "e.g., what are the top 10 rows by revenue?" \
      --width 80) || exit 0
    [[ -z "$question" ]] && exit 0
    exec ai-duck "$file" "$question"
    ;;

  ollama-pull)
    exec ollama-pull
    ;;

  pyinit)
    exec pyinit
    ;;

  report-init)
    exec report-init
    ;;

  *)
    exec "$cmd"
    ;;
esac
