#!/usr/bin/env bash
# ai-config — interactive TUI for configuring the ai-* script suite
#
# Queries Ollama for installed models and lets the user pick which model to
# use for each role (chat, embedding, reasoning).  Saves to
# ~/.config/ai-scripts/config.toml.
#
# Usage:
#   ai-config              # interactive configuration
#   ai-config --show       # print current config and exit
#   ai-config --path       # print config file path and exit
#   ai-config --reset      # delete config file (revert to defaults)
set -euo pipefail

# ── Source shared library ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AI_LIB_PATH:-${SCRIPT_DIR}/lib}/common.sh"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ai-scripts"
CONFIG_FILE="$CONFIG_DIR/config.toml"

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
ai-config — interactive configuration for the ai-* script suite

Usage:
  ai-config              Interactive model & settings configuration
  ai-config --show       Print current configuration
  ai-config --path       Print config file path
  ai-config --reset      Delete config and revert to defaults

Queries Ollama for installed models and lets you pick the chat model,
embedding model, and reasoning model via a gum TUI. Saves settings to
~/.config/ai-scripts/config.toml.

Environment variables (OLLAMA_MODEL, OLLAMA_MODEL_EMBED, etc.) always
override the config file when set.
HELP
  exit 0
fi

# ── --show: print current config ─────────────────────────────────────────────
if [[ "${1:-}" == "--show" ]]; then
  if [ -f "$CONFIG_FILE" ]; then
    gum style --border rounded --padding "0 2" --border-foreground 212 \
      "$(cat "$CONFIG_FILE")"
  else
    echo "No config file found. Using defaults."
    echo ""
    echo "  Chat model:      $(load_config_value models chat "qwen3.5:9b")"
    echo "  Embedding model:  $(load_config_value models embed "qwen3-embedding:0.6b")"
    echo "  Reasoning model:  $(load_config_value models reasoning "lfm2.5-thinking:1.2b")"
    echo ""
    echo "Run 'ai-config' to create a config file."
  fi
  exit 0
fi

# ── --path: print config file path ───────────────────────────────────────────
if [[ "${1:-}" == "--path" ]]; then
  echo "$CONFIG_FILE"
  exit 0
fi

# ── --reset: delete config file ──────────────────────────────────────────────
if [[ "${1:-}" == "--reset" ]]; then
  if [ -f "$CONFIG_FILE" ]; then
    rm "$CONFIG_FILE"
    gum style --foreground 212 "  Config reset. All scripts will use defaults."
  else
    echo "No config file to reset."
  fi
  exit 0
fi

# ── Interactive configuration ────────────────────────────────────────────────

gum style --bold --foreground 212 "󰚩 ai-config — Configure your AI scripts"
echo ""

# Ensure Ollama is running
ensure_ollama

# ── Query installed models ───────────────────────────────────────────────────

echo "Fetching installed models from Ollama..."
MODELS_JSON=$(curl -s http://localhost:11434/api/tags) || {
  gum style --foreground 196 " Failed to reach Ollama at localhost:11434"
  exit 1
}

# Extract model names using Python (handles JSON properly)
ALL_MODELS=$(echo "$MODELS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = data.get('models', [])
for m in sorted(models, key=lambda x: x['name']):
    name = m['name']
    size_gb = m.get('size', 0) / (1024**3)
    param_size = m.get('details', {}).get('parameter_size', '')
    family = m.get('details', {}).get('family', '')
    parts = [name]
    if param_size:
        parts.append(f'({param_size})')
    if family:
        parts.append(f'[{family}]')
    parts.append(f'{size_gb:.1f}GB')
    print(' '.join(parts))
") || ALL_MODELS=""

# Also get just the names for selection
MODEL_NAMES=$(echo "$MODELS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in sorted(data.get('models', []), key=lambda x: x['name']):
    print(m['name'])
") || MODEL_NAMES=""

if [ -z "$MODEL_NAMES" ]; then
  gum style --foreground 196 " No models found! Pull some models first:"
  echo "    ollama pull qwen3.5:9b"
  echo "    ollama pull qwen3-embedding:0.6b"
  exit 1
fi

# ── Show available models ────────────────────────────────────────────────────

gum style --foreground 245 "Installed models:"
echo "$ALL_MODELS" | while read -r line; do
  echo "  $line"
done
echo ""

# ── Read current values ──────────────────────────────────────────────────────

CURRENT_CHAT=$(load_config_value models chat "qwen3.5:9b")
CURRENT_EMBED=$(load_config_value models embed "qwen3-embedding:0.6b")
CURRENT_REASON=$(load_config_value models reasoning "lfm2.5-thinking:1.2b")
CURRENT_TOPK=$(load_config_value search top_k "5")
CURRENT_THRESHOLD=$(load_config_value search threshold "0.8")
CURRENT_DUPE=$(load_config_value organize dupe_threshold "0.12")

# ── Pick chat model ──────────────────────────────────────────────────────────

gum style --bold "Chat model" --foreground 39
gum style --foreground 245 "Used by: ai-cmd, ai-narrative, ai-slide-copy, ai-commit, ai-pr, ai-chat, ai-organize, ai-duck"
echo ""

CHAT_MODEL=$(echo "$MODEL_NAMES" | gum choose \
  --header "Select chat model (current: $CURRENT_CHAT)" \
  --selected "$CURRENT_CHAT" \
  --height 12)

echo ""

# ── Pick embedding model ─────────────────────────────────────────────────────

gum style --bold "Embedding model" --foreground 39
gum style --foreground 245 "Used by: ai-search, ai-chat, ai-organize"
echo ""

EMBED_MODEL=$(echo "$MODEL_NAMES" | gum choose \
  --header "Select embedding model (current: $CURRENT_EMBED)" \
  --selected "$CURRENT_EMBED" \
  --height 12)

echo ""

# ── Pick reasoning model ─────────────────────────────────────────────────────

gum style --bold "Reasoning model" --foreground 39
gum style --foreground 245 "Used by: ai-explain (deep explanations with chain-of-thought)"
echo ""

REASON_MODEL=$(echo "$MODEL_NAMES" | gum choose \
  --header "Select reasoning model (current: $CURRENT_REASON)" \
  --selected "$CURRENT_REASON" \
  --height 12)

echo ""

# ── Advanced settings ────────────────────────────────────────────────────────

CONFIGURE_ADVANCED=$(gum confirm "Configure advanced settings (thresholds, top_k)?" \
  --default=false && echo "yes" || echo "no")

TOPK="$CURRENT_TOPK"
THRESHOLD="$CURRENT_THRESHOLD"
DUPE_THRESHOLD="$CURRENT_DUPE"

if [ "$CONFIGURE_ADVANCED" = "yes" ]; then
  echo ""
  gum style --bold "Search settings" --foreground 39

  TOPK=$(gum input \
    --header "Number of results to return (top_k)" \
    --value "$CURRENT_TOPK" \
    --width 10)

  THRESHOLD=$(gum input \
    --header "Max cosine distance for search results (0.0–2.0)" \
    --value "$CURRENT_THRESHOLD" \
    --width 10)

  echo ""
  gum style --bold "Organize settings" --foreground 39

  DUPE_THRESHOLD=$(gum input \
    --header "Cosine distance threshold for duplicate detection (lower = stricter)" \
    --value "$CURRENT_DUPE" \
    --width 10)
fi

# ── Preview and confirm ──────────────────────────────────────────────────────

echo ""
PREVIEW=$(cat <<EOF
[models]
chat = "$CHAT_MODEL"
embed = "$EMBED_MODEL"
reasoning = "$REASON_MODEL"

[search]
top_k = $TOPK
threshold = $THRESHOLD

[organize]
dupe_threshold = $DUPE_THRESHOLD
EOF
)

gum style --border rounded --padding "0 2" --border-foreground 212 \
  --bold "Configuration preview:" \
  "" \
  "$PREVIEW"

echo ""

if gum confirm "Save this configuration?"; then
  # Write via Python config module for proper formatting
  LIB_DIR="${AI_LIB_PATH:-$SCRIPT_DIR/lib}"
  CHAT_MODEL="$CHAT_MODEL" EMBED_MODEL="$EMBED_MODEL" REASON_MODEL="$REASON_MODEL" \
  TOPK="$TOPK" THRESHOLD="$THRESHOLD" DUPE_THRESHOLD="$DUPE_THRESHOLD" \
  python3 -c "
import os, sys
sys.path.insert(0, os.environ.get('LIB_DIR', '.'))
from config import save_config

config = {
    'models': {
        'chat': os.environ['CHAT_MODEL'],
        'embed': os.environ['EMBED_MODEL'],
        'reasoning': os.environ['REASON_MODEL'],
    },
    'search': {
        'top_k': int(os.environ['TOPK']),
        'threshold': float(os.environ['THRESHOLD']),
    },
    'organize': {
        'dupe_threshold': float(os.environ['DUPE_THRESHOLD']),
    },
}
save_config(config)
" LIB_DIR="$LIB_DIR"

  echo ""
  gum style --foreground 212 "  Configuration saved to $CONFIG_FILE"
  gum style --foreground 245 "  Env vars (OLLAMA_MODEL, etc.) will still override when set."
else
  echo ""
  gum style --foreground 245 "  Configuration not saved."
fi
