#!/usr/bin/env bash
# config.sh — bash interface to the ai-scripts config file
#
# Source this file in any ai-* script that needs config values:
#   source "${SCRIPT_DIR}/../lib/config.sh"
#
# Provides:
#   load_config_value SECTION KEY [DEFAULT]
#     Prints the resolved value for [SECTION].KEY from config.toml,
#     respecting env-var overrides.  Falls back to DEFAULT if not set.

# Locate the Python config helper (sibling of this file)
_CONFIG_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.py"

load_config_value() {
  # Usage: load_config_value <section> <key> [default]
  local section="$1" key="$2" default="${3:-}"
  python3 "$_CONFIG_PY" "$section" "$key" "$default" 2>/dev/null || echo "$default"
}
