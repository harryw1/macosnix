# AI CLI Suite — Gum Codebase Review

A systematic review of the `ai-*` CLI tool suite focusing on gum usage patterns, menu navigation, UX consistency, bugs, and documentation.

---

## Executive Summary

The suite is well-architected with a shared library (`common.sh`) that centralizes Ollama lifecycle, clipboard, temp-file management, and generation. The `gum` integration is generally strong — consistent use of `gum choose` for menus, `gum spin` for loading states, `gum style` for bordered output, and `gum confirm` for destructive actions. However, there are several inconsistencies in output rendering, a few silent failure paths, and opportunities to lean harder on gum's built-in features to reduce custom code.

This review covers five areas: menu navigation, gum implementation, UX improvements, bugs, and documentation.

---

## 1. Menu Navigation and Handling

### What works well

- **The `ai.sh` unified launcher** is excellent — it acts as a proper dispatcher with both interactive (`gum choose`) and direct CLI (`ai cmd`, `ai search`) paths. The tool registry format (`"label|command|description"`) is clean.
- **Every interactive tool follows a consistent generate → preview → act flow.** After LLM output is displayed, the user gets a `gum choose` action menu with Copy / Edit / Regenerate / Abort. This pattern is well-established and intuitive.
- **The `ai-db` main loop** correctly uses `while true` with `clear` + `show_status` to create a persistent TUI that returns to the menu after each action.
- **Sub-menus nest cleanly** — `ai-db` dispatches to `maintenance_menu()` and `analytics_menu()` which each have their own `gum choose` with a "← Back" option.

### Issues

**1.1 — `ai-db check_stale` silently fails on non-JSON output**

`check_stale()` (line 302 of `ai-db.sh`) pipes `stale` output directly to `python3 -c` which expects JSON. If the Python backend prints a plain-text message (e.g., "No stale files") or an error, the JSON parser crashes and the user sees a Python traceback instead of a friendly message.

**Fix:** Guard the JSON parse the same way `manage_orphans()` does — check for the expected shape before parsing:

```bash
check_stale() {
  gum spin --title "Checking for stale entries..." -- \
    sh -c "uv run '$PY_SCRIPT' stale > /tmp/ai-db-stale.txt 2>/dev/null"

  local stale
  stale=$(cat /tmp/ai-db-stale.txt)
  rm -f /tmp/ai-db-stale.txt

  gum style --bold --foreground 39 "Stale Entries"
  gum style --foreground 245 "(Files modified on disk since last indexed)"
  echo ""

  if [ -z "$stale" ] || ! echo "$stale" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    gum style --foreground 114 "  All files are up to date."
  else
    echo "$stale" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data:
    print('  All files are up to date.')
else:
    for d in data:
        print(f\"  {d['filepath']}\")
        print(f\"    indexed: {d['indexed']}  →  on disk: {d['on_disk']}\")
        print()
    print(f'  {len(data)} stale file(s). Re-index to update.')
"
  fi

  echo ""
  gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
}
```

**1.2 — `ai-db` sub-menus don't loop — they return to main after one action**

When you select "Analytics & insights" → "File type breakdown", the result shows, you press Enter, and you're dumped back to the *main* menu — not the analytics sub-menu. For maintenance tasks (vacuum, then rebuild FTS, then clean orphans) this means navigating back through the main menu each time.

**Fix:** Wrap `analytics_menu()` and `maintenance_menu()` in `while true` loops, breaking on "← Back":

```bash
analytics_menu() {
  while true; do
    local action
    action=$(gum choose \
      --header "Analytics:" \
      "← Back" \
      "File type breakdown" \
      "Top files by chunk count" \
      "Top chunks by learned utility") || break

    case "$action" in
      "← Back") break ;;
      "File type breakdown")
        echo ""
        gum style --bold --foreground 39 "File Type Distribution"
        echo ""
        show_file_types
        echo ""
        gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
        ;;
      # ... etc
    esac
  done
}
```

**1.3 — Empty `gum choose` selection causes silent exit in several tools**

When the user presses Escape or Ctrl+C during a `gum choose`, gum returns exit code 1 and an empty string. In `ai-db`, the `case` statement falls through to `*)` which is `;;` (no-op), so the menu loop continues — that's correct. But in `ai-cmd`, `ai-duck`, `ai-narrative`, and `ai-slide-copy`, the action menu has no fallthrough handler, so the script silently exits. This is jarring.

**Fix:** Add a catch-all or `|| exit 0` to action menu `gum choose` calls:

```bash
ACTION=$(gum choose \
  --header "What would you like to do?" \
  "  Run it" \
  "..." \
  "  Abort") || { echo "Aborted."; exit 0; }
```

**1.4 — `ai-narrative` and `ai-slide-copy` regenerate loses interactive context (partially)**

Both tools save `$DATA_INPUT` to a temp file before `exec`-ing themselves, which preserves the raw data. But the user's *choices* (output type, audience, number of slides, style) are lost — the regenerated run re-prompts for everything. This is friction for "I like the settings, just give me a different draft."

**Fix:** Pass the choices as environment variables through the `exec`:

```bash
"󰑐  Regenerate")
  _REGEN_FILE=$(mktemp)
  printf '%s' "$DATA_INPUT" > "$_REGEN_FILE"
  OUTPUT_TYPE="$OUTPUT_TYPE" AUDIENCE="$AUDIENCE" \
    exec bash "${BASH_SOURCE[0]}" "$_REGEN_FILE"
  ;;
```

Then at the top of each script, check for these env vars before prompting:

```bash
OUTPUT_TYPE="${OUTPUT_TYPE:-$(gum choose --header "What are you writing?" ...)}"
```

---

## 2. Gum Implementation Evaluation

### What works well

- **`gum spin` is used correctly everywhere** for blocking operations (Ollama calls, DB operations, file scanning). The custom `--title` with Nerd Font icons is a nice touch.
- **`gum style --border` is used consistently** — `double` for "proposed" content (commands, commit messages, PR descriptions), `rounded` for "final" results (explanations, narratives, query results). This implicit visual language is well-applied.
- **`gum confirm`** is used for all destructive actions (delete chunks, remove orphans, apply organize changes, delete DB) with appropriate `--affirmative`/`--negative` labels.
- **`gum choose --cursor "▸ "`** is used in both `ai.sh` and `ai-db.sh` for the main menus, giving them a distinct "app" feel.
- **`gum filter`** is used appropriately in `ai-db browse_files()` for searching indexed files — the right tool for a large, searchable list.

### Issues and opportunities

**2.1 — `gum spin` output is discarded in several places — use `--show-output` or `--show-error`**

In `ai-db.sh` lines 79, 174, 243, 265, 291, 333, 347, and 419, `gum spin` runs a command and pipes output to a temp file so it can be parsed afterward. This is the correct pattern when you need to parse structured output. However, for `--vacuum` (line 79), the CLI flag path just shows the spinner and reports "Database vacuumed" without showing the actual size savings. Consider using `--show-output` for quick feedback:

```bash
# Instead of silently spinning then printing a generic message:
gum spin --title "Vacuuming database..." -- uv run "$PY_SCRIPT" vacuum
gum style --foreground 212 " Database vacuumed."

# Show the structured result:
gum spin --title "Vacuuming database..." --show-output -- uv run "$PY_SCRIPT" vacuum
```

**2.2 — Custom `progress_spinner()` in `common.sh` reimplements what `gum spin` does**

The `progress_spinner()` function (lines 200–256 of `common.sh`) is a hand-rolled spinner that polls a progress file and updates the title dynamically. This is 56 lines of cursor manipulation, ANSI escape codes, and background process management. It works, but it's fragile (the `trap ... RETURN` for cursor restoration could conflict with the global EXIT trap, and `kill -0` polling at 100ms is CPU-hungry).

Currently this is only used by `ai-chat.sh` (line 96). Consider one of these alternatives:

**Option A — Sequential `gum spin` calls per stage:**
If the Python backend can be split into a retrieval step and a generation step, run two sequential spinners:

```bash
gum spin --title "󰚩  Retrieving relevant chunks..." -- \
  sh -c 'uv run "$PY_SCRIPT" --retrieve "$QUERY" --scope "$SCOPE" > "$CHUNKS_FILE"'

gum spin --title "󰚩  Generating answer with ${CHAT_MODEL}..." -- \
  sh -c 'uv run "$PY_SCRIPT" --generate --chunks "$CHUNKS_FILE" > "$RESULT_FILE"'
```

**Option B — Use `gum spin` with a simpler title update:**
If you need the dynamic title, at least replace the raw ANSI manipulation with `gum spin`'s `--show-error` to surface any failures.

**2.3 — `gum format` (markdown rendering) is used inconsistently**

Some tools pipe LLM output through `gum format` before wrapping in `gum style`:

- `ai-explain.sh` line 121: `gum format` → `gum style`
- `ai-narrative.sh` line 132: `gum format` → `gum style`
- `ai-slide-copy.sh` line 158: `gum format` → `gum style`
- `ai-cmd.sh` line 182: `gum format` → `gum style` (in `describe_result`)

But others skip `gum format` entirely:

- `ai-chat.sh` line 170: raw text → `gum style` (no markdown rendering)
- `ai-commit.sh` line 104: raw text → `gum style`
- `ai-pr.sh` line 137: raw text → `gum style`

This means markdown-like output (bullets, bold) renders correctly in some tools but shows raw `*` and `-` characters in others. Since the LLM prompts explicitly say "no markdown" for commit messages and PR descriptions, this is actually correct for those tools. But `ai-chat` should probably use `gum format` since its answers may contain markdown.

**Fix for `ai-chat.sh`:**

```bash
FORMATTED_ANSWER=$(printf '%s' "$ANSWER" | gum format)
gum style \
  --width "$TERM_WIDTH" \
  --border rounded --padding "1 2" \
  "$FORMATTED_ANSWER"
```

**2.4 — "Press Enter to continue" pattern uses `gum input` — use `gum confirm` or just `read`**

In `ai-db.sh`, the "Press Enter to continue" prompt is implemented as:

```bash
gum input --header "Press Enter to continue..." --placeholder "" >/dev/null 2>&1 || true
```

This works but it renders a text input field with a cursor, which is visually misleading (it looks like it expects text input). A simpler approach:

```bash
# Option A: plain read (no gum overhead)
read -rsp "  Press Enter to continue..."

# Option B: gum confirm with single button
gum confirm "Continue?" --affirmative "OK" --negative "" --default
```

Or create a helper in `common.sh`:

```bash
pause() {
  gum style --faint "  Press Enter to continue…"
  read -rs
}
```

**2.5 — `gum log` is underused — only appears in 3 places**

`gum log` is used in `ai-search.sh` (line 160), `ai-organize.sh` (lines 160, 391, 394, 403, 407), and nowhere else. Many places that currently use `echo` with Nerd Font icons or `gum style --foreground` for informational messages would benefit from `gum log`:

```bash
# Instead of:
echo "  Found $FILE_COUNT file(s)."

# Use:
gum log --level info "Found $FILE_COUNT file(s)."

# Instead of:
echo " No query generated. Is '$MODEL' pulled? Run: ollama pull $MODEL"

# Use:
gum log --level error "No query generated. Is '$MODEL' pulled?"
gum log --level info "Run: ollama pull $MODEL"
```

This gives you structured, color-coded, timestamped messages for free, and removes the reliance on manually matching Nerd Font error/success icons.

**2.6 — `ai-search.sh` results use hardcoded ANSI instead of `gum style`**

Lines 163–193 of `ai-search.sh` build result output with raw ANSI escape codes (`\033[38;5;111m`, etc.). The same pattern appears in `ai-chat.sh` (lines 176–212) for source display. This bypasses the Catppuccin theme set by the gum wrapper.

**Fix:** Use `gum style` for each result entry, or at minimum, define the colors as variables sourced from the gum theme environment. A helper function in `common.sh` would standardize this:

```bash
# common.sh
color_blue()  { gum style --foreground 111 "$@"; }
color_green() { gum style --foreground 114 "$@"; }
color_gray()  { gum style --foreground 244 "$@"; }
```

---

## 3. UX Improvements

### 3.1 — Standardize action menu items across all tools

Currently the action menus are inconsistent:

| Tool | Actions offered |
|------|----------------|
| ai-cmd | Run / Copy / Edit then run / Regenerate / Abort |
| ai-commit | Stage all & commit / Commit staged / Edit then commit / Regenerate / Abort |
| ai-pr | Push & open PR / Copy / Edit then open / Regenerate / Abort |
| ai-duck | Run query / Edit then run / Regenerate / Abort |
| ai-narrative | Copy / Save to file / Regenerate / Abort |
| ai-slide-copy | Copy all / Review and edit / Save to file / Regenerate / Abort |
| ai-chat | Ask another / Copy answer / Abort |
| ai-explain | *(no action menu — output only)* |

**Recommendations:**
- **Every tool that generates text should offer Copy to clipboard.** `ai-duck`'s first action menu is missing it (it's in the post-run menu but not the initial one).
- **"Abort" should consistently be the last item.** It already is everywhere — good.
- **Use a standard icon set:** `  ` for primary action, `󰆏` for copy, `󰏫` for edit, `󰑐` for regenerate, `` for abort. This is already mostly consistent.

### 3.2 — Add `gum pager` for long outputs

When `ai-search` returns many results, `ai-organize` generates a large plan, or `ai-duck` returns a wide table, the output scrolls off screen. `gum pager` (available in gum) could wrap long outputs:

```bash
if [ "$(echo "$RESULTS" | wc -l)" -gt 30 ]; then
  echo "$RESULTS" | gum pager
else
  echo "$RESULTS"
fi
```

### 3.3 — Use `gum table` for structured data in `ai-duck` and `ai-db`

`ai-duck` currently displays DuckDB results as raw terminal table output inside a `gum style` box. For tabular data, `gum table` provides better formatting with column alignment:

```bash
# Instead of raw duckdb output in a style box:
duckdb -csv -c "$SQL" | gum table
```

### 3.4 — Standardize empty-result messaging

Different tools handle "nothing found" differently:

- `ai-db browse_files`: `gum style --foreground 196 "  No files indexed."`
- `ai-db do_search`: `gum style --foreground 196 "  No results found."`
- `ai-search`: `echo "No results found."`
- `ai-duck run_query`: `gum style --border rounded --padding "1 2" "No results returned."`
- `ai-organize`: `gum log --level warn "No changes suggested for this directory."`

**Recommendation:** Create a helper:

```bash
# common.sh
show_empty() {
  # Usage: show_empty "No results found."
  gum style --foreground 245 --italic "  $1"
}
```

### 3.5 — The `ai.sh` launcher should show category headers

The tool list in `ai.sh` is flat — all 14 tools in a single `gum choose`. The registry has comment-delimited categories (Git, Generate, Data, Search, Setup) but these aren't rendered. Adding styled separator lines or using `gum choose` with disabled items as headers would improve scanability:

```bash
TOOLS=(
  "─── Git ─────────────────────────────|:|"
  "  git-ai-commit  ...
  ...
)
```

Or render the labels with `gum style` before passing to `gum choose`.

---

## 4. Bugs

### 4.1 — `ollama_generate` merges stderr into stdout (line 188 of `common.sh`)

The response parsing block:

```bash
response=$(MSG_FILE="$msg_file" python3 -c "..." 2>&1 || true)
```

The `2>&1` merges stderr (error messages like "Ollama error: model not found") into `$response`, which then gets printed to the caller as if it were the LLM's answer. This means error messages end up displayed inside the styled output box.

**Fix:** Capture stderr separately:

```bash
local err_file
err_file=$(mktemp)
_register_cleanup "$err_file"

response=$(MSG_FILE="$msg_file" python3 -c "
import json, os, sys
try:
    with open(os.environ['MSG_FILE']) as f:
        d = json.load(f)
    if 'error' in d:
        print('Ollama error: ' + d['error'], file=sys.stderr)
        sys.exit(1)
    print(d.get('response', ''))
except Exception as e:
    with open(os.environ['MSG_FILE']) as f:
        raw = f.read()[:200]
    print(f'Failed to parse Ollama response: {e}', file=sys.stderr)
    if raw:
        print(f'Raw response: {raw}', file=sys.stderr)
    sys.exit(1)
" 2>"$err_file") || {
    local err_msg
    err_msg=$(cat "$err_file")
    echo "$err_msg" >&2
    return 1
  }
```

### 4.2 — `ai-db do_search` uses `python3` instead of `uv run` for the search call

Line 243 of `ai-db.sh`:

```bash
gum spin --title "..." -- \
  sh -c "python3 '$PY_SCRIPT' search '$query' > /tmp/ai-db-search-results.txt 2>/dev/null"
```

But every other call to `$PY_SCRIPT` in the same file uses `uv run`. The search script likely has inline `# /// script` dependencies (sqlite-vec, etc.) that won't be available to bare `python3`. This would cause the search to silently fail and return empty results.

**Fix:** Change `python3` to `uv run`:

```bash
sh -c "uv run '$PY_SCRIPT' search '$query' > /tmp/ai-db-search-results.txt 2>/dev/null"
```

### 4.3 — `ai-db do_search` and `manage_orphans` use hardcoded `/tmp/` paths

Lines 243, 246, 266, 269 use paths like `/tmp/ai-db-search-results.txt`. These should use `mktemp` and `_register_cleanup` like the rest of the codebase to avoid collisions and ensure cleanup:

```bash
do_search() {
  ensure_ollama

  local query
  query=$(gum input ...) || return
  [ -z "$query" ] && return

  local results_file
  results_file=$(mktemp)
  _register_cleanup "$results_file"

  gum spin --title "..." -- \
    sh -c "uv run '$PY_SCRIPT' search '$query' > '$results_file' 2>/dev/null"

  local results
  results=$(cat "$results_file")
  # ...
}
```

### 4.4 — `ai-search.sh` query injection via shell interpolation

Line 150:

```bash
gum spin --title "..." -- \
  sh -c "uv run \"$PY_SCRIPT\" --search \"$SEARCH_QUERY\" > \"$RESULTS_FILE\""
```

If `$SEARCH_QUERY` contains shell metacharacters (quotes, backticks, `$(...)`), this breaks or could execute arbitrary commands. Use `env` to pass the variable safely:

```bash
gum spin --title "..." -- \
  env QUERY="$SEARCH_QUERY" PY="$PY_SCRIPT" OUT="$RESULTS_FILE" \
  sh -c 'uv run "$PY" --search "$QUERY" > "$OUT"'
```

This pattern should be applied to several other `sh -c` calls throughout the codebase where user input is interpolated (e.g., `ai-db.sh` lines 243, 266, 291).

### 4.5 — `make_tempfiles` uses `eval` for variable assignment (line 341 of `common.sh`)**

```bash
eval "$varname='$tmpf'"
```

If `$tmpf` contains single quotes (unlikely for `mktemp` output, but possible on exotic systems), this breaks. Use `printf -v` instead:

```bash
printf -v "$varname" '%s' "$tmpf"
```

### 4.6 — `ai-chat.sh` suppresses all stderr from the RAG pipeline (line 100)

```bash
uv run "$PY_SCRIPT" --chat "$QUERY" --scope "$SCOPE" \
  --progress-file "$PROGRESS_FILE" > "$RESULT_FILE" 2>/dev/null
```

If the Python script fails (import error, missing dependency, DB corruption), the error is swallowed entirely. The user sees "No answer generated" with no diagnostic info.

**Fix:** Redirect stderr to a file and display it on failure:

```bash
ERR_FILE=$(mktemp)
_register_cleanup "$ERR_FILE"

progress_spinner "$PROGRESS_FILE" "..." -- \
  sh -c 'uv run "$PY_SCRIPT" --chat "$QUERY" --scope "$SCOPE" \
    --progress-file "$PROGRESS_FILE" > "$RESULT_FILE" 2>"$ERR_FILE"'

if [ ! -s "$RESULT_FILE" ] && [ -s "$ERR_FILE" ]; then
  gum log --level error "RAG pipeline failed:"
  cat "$ERR_FILE" >&2
fi
```

---

## 5. Documentation and Code Comments

### What works well

- **Every script has a clear header comment** with description and usage examples. These serve as excellent inline documentation.
- **`common.sh` has a "Provides:" block** listing every exported function with a one-line signature. This is the right pattern for a shared library.
- **`config.sh` has a docstring** explaining the `load_config_value` interface.
- **The `test-rebuild.sh` script** is thorough and well-organized — it serves as living documentation of what the suite depends on.

### Issues

**5.1 — `ollama_generate` options are undocumented at call sites**

The function accepts `--temperature`, `--num_predict`, `--num_ctx`, `--think`, and `--spinner`. These are documented in the function header, but at call sites the chosen values are unexplained. For example, why does `ai-cmd` use `temperature=0.1` while `ai-explain` uses `0.6`? A brief inline comment would help:

```bash
RAW=$(ollama_generate "$PROMPT_FILE" "$MODEL" \
  --temperature 0.1 \   # near-deterministic: we want one exact command
  --num_predict 200 \   # commands are short
  --num_ctx 2048 \      # small context: just the task description
  --spinner "...")
```

**5.2 — `pipeline_post` is called but its purpose isn't documented in calling scripts**

`ai-cmd.sh`, `ai-explain.sh`, `ai-commit.sh`, and `ai-pr.sh` all call `pipeline_post()`, but there's no comment explaining what it does or why. The function header in `common.sh` says "verification + feedback logging" but this doesn't explain what "verification" means in practice, or what the feedback is used for.

Add a one-liner at each call site:

```bash
# Verify the generated command against known patterns and log for feedback learning
POST_RESULT=$(pipeline_post "ai-cmd" "$QUERY" "$CMD")
```

**5.3 — The `ai.sh` tool registry format isn't documented**

The `TOOLS` array uses a `"label|command|description"` pipe-delimited format, but this isn't explained anywhere. A brief comment would help:

```bash
# Format: "display_label|command_name|description"
# display_label: shown in gum choose menu (first word must match command_name)
# command_name:  the actual binary to exec
# description:   shown after selection, before dispatch
```

**5.4 — No inline documentation for the Catppuccin color palette in `ai-organize.sh`**

The Python display code (lines 211–222) defines a color palette with short variable names (`lav`, `grn`, `ylw`, `mau`, `gry`, `red`, `blu`, `tl`). The comments are good, but there's no note explaining *why* these specific colors were chosen or that they match Catppuccin Macchiato. If someone changes the gum wrapper theme, they won't know these hardcoded values need updating too.

**Fix:** Add a note:

```python
# These colors match the Catppuccin Macchiato palette used by the gum
# wrapper (see modules/home-manager/gum.nix).  If you change the theme,
# update these values to match.
```

**5.5 — `progress_spinner` needs a usage example**

The function header describes the API but doesn't show a concrete call. Add:

```bash
# Example:
#   progress_spinner "$PROGRESS_FILE" "Working..." -- \
#     my_command --progress-file "$PROGRESS_FILE" arg1 arg2
#
# The subprocess writes stage names like "Step 1: Indexing" to PROGRESS_FILE.
```

---

## Summary of Recommended Changes

### Priority 1 — Bugs (fix now)

| # | Issue | File | Effort |
|---|-------|------|--------|
| 4.1 | `ollama_generate` merges stderr into response | `common.sh:188` | Small |
| 4.2 | `do_search` uses `python3` instead of `uv run` | `ai-db.sh:243` | Trivial |
| 4.3 | Hardcoded `/tmp/` paths instead of `mktemp` | `ai-db.sh:243,266` | Small |
| 4.4 | Shell injection in `sh -c` query interpolation | `ai-search.sh:150` + others | Medium |
| 4.6 | RAG pipeline stderr silently swallowed | `ai-chat.sh:100` | Small |

### Priority 2 — UX consistency (do next)

| # | Issue | File | Effort |
|---|-------|------|--------|
| 1.3 | Empty `gum choose` → silent exit | All action menus | Small |
| 2.3 | `gum format` not used in `ai-chat` | `ai-chat.sh:170` | Trivial |
| 2.4 | "Press Enter" uses `gum input` instead of `read` | `ai-db.sh` | Trivial |
| 2.5 | `gum log` underused for info/error messages | All scripts | Medium |
| 3.4 | Inconsistent empty-result messaging | All scripts | Small |

### Priority 3 — Architecture improvements (plan for)

| # | Issue | File | Effort |
|---|-------|------|--------|
| 1.2 | Sub-menus don't loop in `ai-db` | `ai-db.sh` | Small |
| 1.4 | Regenerate loses interactive choices | `ai-narrative.sh`, `ai-slide-copy.sh` | Medium |
| 2.2 | Custom spinner reimplements `gum spin` | `common.sh:200-256` | Large |
| 2.6 | Hardcoded ANSI instead of gum in search results | `ai-search.sh`, `ai-chat.sh` | Medium |
| 3.5 | Launcher menu needs category headers | `ai.sh` | Small |

### Priority 4 — Documentation (ongoing)

| # | Issue | File | Effort |
|---|-------|------|--------|
| 5.1 | Undocumented temperature/token choices at call sites | All scripts | Small |
| 5.2 | `pipeline_post` purpose unexplained at call sites | `ai-cmd`, `ai-explain`, etc. | Trivial |
| 5.3 | Tool registry format undocumented | `ai.sh` | Trivial |
| 5.4 | Catppuccin palette not linked to gum theme | `ai-organize.sh` | Trivial |
| 5.5 | `progress_spinner` needs usage example | `common.sh` | Trivial |
