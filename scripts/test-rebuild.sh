#!/usr/bin/env bash
# test-rebuild.sh — Post-rebuild health checks for the ai-* CLI suite
#
# Run after `make switch` to verify everything landed correctly.
# Usage: bash scripts/test-rebuild.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

# ── Colours & helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf "${GREEN}  ✓${RESET} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}  ✗${RESET} %s\n" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf "${YELLOW}  ○${RESET} %s (skipped)\n" "$1"; }
section() { printf "\n${BOLD}── %s ──${RESET}\n" "$1"; }

# ── 1. Binary availability ────────────────────────────────────────────────────

section "Binaries on PATH"

BINS=(
  # AI CLI tools (from scripts.nix)
  git-ai-commit ai-explain ai-pr ai-search ai-cmd ai-chat
  ai-narrative ai-duck ai-slide-copy ai-organize ai-db ai-config ai-help
  ollama-pull pyinit report-init mdconvert
  # Core dependencies
  gum ollama python3 curl jq gh uv duckdb just
)

for bin in "${BINS[@]}"; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "$bin"
  else
    fail "$bin — not found"
  fi
done

# ── 2. Gum wrapper (Catppuccin theming) ───────────────────────────────────────

section "Gum wrapper"

# The nix gum wrapper should set GUM_SPIN_SPINNER_FOREGROUND when invoked.
# We can check that `gum` on PATH points to the wrapper, not raw gum.
GUM_PATH=$(command -v gum 2>/dev/null || true)
if [ -n "$GUM_PATH" ]; then
  if grep -q "GUM_SPIN_SPINNER_FOREGROUND" "$GUM_PATH" 2>/dev/null; then
    pass "gum wrapper has Catppuccin theme injection"
  else
    fail "gum on PATH does not appear to be the themed wrapper"
  fi
else
  fail "gum not found"
fi

# ── 3. Ollama connectivity ────────────────────────────────────────────────────

section "Ollama"

if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  pass "Ollama API reachable (localhost:11434)"

  # Check required models
  MODELS=("qwen3.5:9b" "qwen3-embedding:0.6b" "lfm2.5-thinking:1.2b")
  TAGS=$(curl -s http://localhost:11434/api/tags)

  for model in "${MODELS[@]}"; do
    if echo "$TAGS" | grep -q "\"$model\""; then
      pass "Model: $model"
    else
      fail "Model: $model — not pulled (run: ollama-pull)"
    fi
  done
else
  skip "Ollama not running — model checks skipped (start Ollama and re-run)"
fi

# ── 4. Python library imports ─────────────────────────────────────────────────

section "Python libraries"

# config.py should parse without error
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if python3 "$SCRIPT_DIR/lib/config.py" models chat "test-fallback" >/dev/null 2>&1; then
  pass "config.py loads and resolves values"
else
  fail "config.py failed to execute"
fi

# Check that sqlite-vec extension is loadable (needed by embeddings.py)
if python3 -c "import sqlite3; import sqlite_vec; db = sqlite3.connect(':memory:'); db.enable_load_extension(True); sqlite_vec.load(db); db.execute('SELECT vec_version()')" 2>/dev/null; then
  pass "sqlite-vec extension loads"
else
  # Try with uv in case it's an inline-script dependency
  if uv run --with sqlite-vec python3 -c "import sqlite3; import sqlite_vec; db = sqlite3.connect(':memory:'); db.enable_load_extension(True); sqlite_vec.load(db); db.execute('SELECT vec_version()')" 2>/dev/null; then
    pass "sqlite-vec extension loads (via uv)"
  else
    fail "sqlite-vec — cannot load extension"
  fi
fi

# ── 5. Config resolution ─────────────────────────────────────────────────────

section "Configuration"

# Verify config.py returns expected defaults
CHAT_MODEL=$(python3 "$SCRIPT_DIR/lib/config.py" models chat "MISSING" 2>/dev/null) || CHAT_MODEL="MISSING"
EMBED_MODEL=$(python3 "$SCRIPT_DIR/lib/config.py" models embed "MISSING" 2>/dev/null) || EMBED_MODEL="MISSING"
REASON_MODEL=$(python3 "$SCRIPT_DIR/lib/config.py" models reasoning "MISSING" 2>/dev/null) || REASON_MODEL="MISSING"

if [ "$CHAT_MODEL" != "MISSING" ]; then
  pass "models.chat = $CHAT_MODEL"
else
  fail "models.chat — could not resolve"
fi

if [ "$EMBED_MODEL" != "MISSING" ]; then
  pass "models.embed = $EMBED_MODEL"
else
  fail "models.embed — could not resolve"
fi

if [ "$REASON_MODEL" != "MISSING" ]; then
  pass "models.reasoning = $REASON_MODEL"
else
  fail "models.reasoning — could not resolve"
fi

# Verify env-var override works
OVERRIDE_RESULT=$(OLLAMA_MODEL="test-override" python3 "$SCRIPT_DIR/lib/config.py" models chat "MISSING" 2>/dev/null) || OVERRIDE_RESULT="MISSING"
if [ "$OVERRIDE_RESULT" = "test-override" ]; then
  pass "env-var override (OLLAMA_MODEL) works"
else
  fail "env-var override — expected 'test-override', got '$OVERRIDE_RESULT'"
fi

# ── 6. common.sh sourceable ──────────────────────────────────────────────────

section "Shared library (common.sh)"

if bash -c "source '$SCRIPT_DIR/lib/common.sh' && type ensure_ollama >/dev/null 2>&1 && type clip_copy >/dev/null 2>&1 && type ollama_generate >/dev/null 2>&1 && type strip_think_blocks >/dev/null 2>&1 && type term_width >/dev/null 2>&1 && type make_tempfiles >/dev/null 2>&1 && type pipeline_post >/dev/null 2>&1"; then
  pass "common.sh sources cleanly, all functions defined"
else
  fail "common.sh — failed to source or missing functions"
fi

# Test strip_think_blocks (tags on separate lines, matching real Ollama output)
STRIPPED=$(printf '<think>\ninternal reasoning\n</think>\nHello world\n' | bash -c "source '$SCRIPT_DIR/lib/common.sh' && strip_think_blocks")
if echo "$STRIPPED" | grep -q "Hello world"; then
  pass "strip_think_blocks works"
else
  fail "strip_think_blocks — expected 'Hello world' in output, got '$STRIPPED'"
fi

# Test term_width returns a number
TW=$(bash -c "source '$SCRIPT_DIR/lib/common.sh' && term_width")
if [[ "$TW" =~ ^[0-9]+$ ]] && [ "$TW" -le 100 ]; then
  pass "term_width returns $TW (≤100)"
else
  fail "term_width — expected number ≤100, got '$TW'"
fi

# ── 7. DuckDB ────────────────────────────────────────────────────────────────

section "DuckDB"

DUCKDB_VER=$(duckdb -version 2>/dev/null || true)
if [ -n "$DUCKDB_VER" ]; then
  pass "duckdb available ($DUCKDB_VER)"
else
  fail "duckdb — not working"
fi

# Quick smoke test: can it query inline data?
DUCK_RESULT=$(duckdb -noheader -csv -c "SELECT 1 + 1 AS result;" 2>/dev/null || true)
if [ "$DUCK_RESULT" = "2" ]; then
  pass "duckdb inline query works"
else
  fail "duckdb inline query — expected '2', got '$DUCK_RESULT'"
fi

# ── 8. GitHub CLI ─────────────────────────────────────────────────────────────

section "GitHub CLI"

if gh auth status >/dev/null 2>&1; then
  pass "gh authenticated"
else
  fail "gh — not authenticated (run: gh auth login)"
fi

# ── 9. Claude Code ───────────────────────────────────────────────────────────

section "Claude Code"

if command -v claude >/dev/null 2>&1; then
  CLAUDE_VER=$(claude --version 2>/dev/null || echo "unknown")
  pass "claude-code available ($CLAUDE_VER)"
else
  fail "claude-code — not found"
fi

# ── 10. Ollama generation smoke test ─────────────────────────────────────────

section "Ollama generation (smoke test)"

if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  SMOKE_RESPONSE=$(curl -sf http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen3.5:9b","prompt":"Reply with only the word HELLO.","stream":false,"options":{"num_predict":20,"temperature":0}}' 2>/dev/null || true)

  if [ -n "$SMOKE_RESPONSE" ]; then
    # Thinking models may put content in 'thinking' rather than 'response',
    # or 'response' may contain think blocks. Check both fields and strip
    # think blocks before deciding.
    SMOKE_CHECK=$(echo "$SMOKE_RESPONSE" | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
resp = d.get('response', '') or ''
think = d.get('thinking', '') or ''
# Strip <think>...</think> blocks from response
resp_clean = re.sub(r'<think>.*?</think>', '', resp, flags=re.DOTALL).strip()
combined = (resp_clean + ' ' + think).strip()
if combined:
    print(f'ok:{len(combined)}')
elif 'error' in d:
    print(f'error:{d[\"error\"]}')
else:
    print('empty')
" 2>/dev/null || echo "parse_fail")
    case "$SMOKE_CHECK" in
      ok:*)
        chars="${SMOKE_CHECK#ok:}"
        pass "Ollama generation: qwen3.5:9b responded ($chars chars)"
        ;;
      error:*)
        fail "Ollama generation: API error — ${SMOKE_CHECK#error:}"
        ;;
      empty)
        fail "Ollama generation: empty response from qwen3.5:9b"
        ;;
      *)
        fail "Ollama generation: could not parse response"
        ;;
    esac
  else
    fail "Ollama generation: no response from qwen3.5:9b"
  fi

  # Embedding smoke test
  EMBED_RESPONSE=$(curl -sf http://localhost:11434/api/embed \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen3-embedding:0.6b","input":"test embedding"}' 2>/dev/null || true)

  if [ -n "$EMBED_RESPONSE" ]; then
    EMBED_CHECK=$(echo "$EMBED_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
emb = d.get('embeddings', d.get('embedding', []))
if isinstance(emb, list) and len(emb) > 0:
    if isinstance(emb[0], list):
        print(len(emb[0]))
    else:
        print(len(emb))
else:
    print(0)
" 2>/dev/null || echo "0")
    if [ "$EMBED_CHECK" -gt 0 ] 2>/dev/null; then
      pass "Ollama embedding: qwen3-embedding returns vectors (dim=$EMBED_CHECK)"
    else
      fail "Ollama embedding: unexpected response shape"
    fi
  else
    fail "Ollama embedding: no response"
  fi
else
  skip "Ollama not running — generation smoke test skipped"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

section "Summary"
printf "  ${GREEN}Passed: %d${RESET}  ${RED}Failed: %d${RESET}  ${YELLOW}Skipped: %d${RESET}\n\n" "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  printf "${RED}Some checks failed. Review the output above.${RESET}\n"
  exit 1
else
  printf "${GREEN}All checks passed!${RESET}\n"
  exit 0
fi
