# CLI Tools Design Critique

A focused review of error handling, output formatting, and help text across your `ai-*` tool suite, `pyinit`, `report-init`, and supporting wrappers.

---

## First Impression

This is an impressively cohesive toolkit. The consistent use of `gum` for interactive menus, the Catppuccin theming layer, and the uniform "generate → preview → act" flow across all tools creates a strong sense of identity. Every tool *feels* like it belongs to the same family. That's rare in personal CLI suites and worth calling out.

The three areas below are where I see room to tighten things up.

---

## 1. Error Handling

### What works well

- **Guard clauses are thorough.** Every script validates preconditions early: git repo checks, file existence, Ollama connectivity, DuckDB availability. The pattern of checking before doing anything expensive is consistent and correct.
- **Ollama auto-start is genuinely helpful.** The "start Ollama, wait, continue" pattern avoids a frustrating failure mode where you'd have to re-run the command.
- **Temp file cleanup via `trap`** is present in every script. Good hygiene.
- **Exit codes are correct.** Errors exit 1, user-initiated aborts exit 0.

### Issues to address

**1.1 — The Ollama wait loop has no timeout**
Every script has this pattern:

```bash
while ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; do
  sleep 1
  echo -n "."
done
```

If Ollama crashes on startup or the port is blocked, this loops forever. A simple counter (e.g. bail after 30 seconds) would prevent a hung terminal.

**1.2 — `curl` failures during API calls are silently swallowed**
The generation call pipes curl output to a file with `2>/dev/null`, then parses the file with Python. If the API returns an HTTP error, malformed JSON, or the connection drops mid-stream, the Python parser silently returns empty and you get the generic "No message generated" error. You lose the actual failure reason.

Consider: check `curl`'s exit code, or have the Python parser surface the raw response when JSON parsing fails.

**1.3 — `ai-commit` has a case-match bug on "Edit then commit"**
Line 151 of `ai-commit.sh`:
```
"󰏫   Edit then commit")
```
has **three spaces** between the icon and "Edit", but the `gum choose` option on line 133:
```
"󰏫  Edit then commit"
```
has **two spaces**. This means the "Edit then commit" branch will never match. The case falls through silently and the script exits without feedback.

**1.4 — `eval "$CMD"` in ai-cmd is a shell injection surface**
Line 150 of `ai-cmd.sh` runs `eval "$CMD"` on LLM-generated output. The LLM could hallucinate a destructive command (e.g., `rm -rf /`). The confirmation prompt helps, but the displayed command could differ from what `eval` actually executes if the string contains hidden characters or expansions. Using `bash -c "$CMD"` in a subshell, or better yet, printing it and asking the user to paste-and-run, would be safer.

**1.5 — No error handling on `git push` in ai-pr**
Lines 178 and 193 run `git push -u origin "$CURRENT_BRANCH"` with no error check. If the push fails (auth issue, protected branch, no remote), the script continues to `gh pr create`, which will also fail — now you get two confusing errors instead of one clear one.

**1.6 — `ai-narrative` regenerate loses interactive context**
Line 189: `exec bash "${BASH_SOURCE[0]}" "$@"` passes the original `$@`, which is the raw CLI args. But if the user entered data interactively (via `gum write`), that input is lost. The regenerated run starts from scratch, re-prompting for data, output type, and audience. The other tools that regenerate (like `ai-duck`) handle this correctly by passing the captured values.

---

## 2. Output Formatting

### What works well

- **The `gum style` boxes are clean and readable.** Double borders for "proposed" content, rounded borders for results — that implicit visual language works.
- **Terminal width detection with fallback** is consistent across tools.
- **The `ai-organize` plan display is excellent.** The tree view, color-coded operation types, grouped moves, and footer summary bar is the best-formatted output in the suite. This is the gold standard the other tools should aspire to.
- **ANSI color palette is consistent** (Catppuccin-derived blues, greens, grays) across the Python scripts.

### Issues to address

**2.1 — `gum style` can't word-wrap long single-line strings**
When the LLM generates a commit message, SQL query, or narrative as one long line, `gum style` truncates rather than wraps inside its box. This is most visible in `ai-duck` where SQL queries are often long single-liners. Piping through `fold -s -w $((TERM_WIDTH - 8))` before passing to `gum style` would help.

**2.2 — The Nerd Font icons are invisible without the right font**
Every tool uses Nerd Font icons (󰚩, 󰆍, 󰺮, etc.). These render as blank boxes in terminals without a patched font. Since this is your personal setup, that's probably fine — but worth noting if you ever share these tools. A fallback to plain-text icons (or a `--no-icons` flag) would make them portable.

**2.3 — Inconsistent action menu icon spacing**
Some menus use two spaces after the icon (`"  Run it"`), others use one, and the edit option in `ai-commit` has three. Since `gum choose` aligns based on the full string, inconsistent spacing makes the menu labels visually ragged. A quick pass to normalize to two spaces everywhere would clean this up.

**2.4 — `ai-search` results use raw ANSI while everything else uses `gum style`**
The search results renderer (lines 164-194 of `ai-search.sh`) builds its own ANSI output with hardcoded color codes, while every other tool delegates styling to `gum`. This means search results won't respect the Catppuccin light/dark theme from your `gum-wrapped` script. Consider either routing through `gum style` or reading the same theme variables.

**2.5 — `ai-chat` answer rendering differs from everything else**
Line 112: `printf '%s\n' "$ANSWER" | gum format` uses `gum format` (markdown rendering), while every other tool uses `gum style` (box rendering). This is actually a reasonable choice for prose answers, but the visual inconsistency with the rest of the suite is noticeable. Not necessarily a bug — more of a conscious design choice to document.

**2.6 — `pbcopy` is macOS-only**
Several scripts use `pbcopy` for clipboard. If you ever run these on a Linux box (NixOS, WSL), they'll fail silently. A small helper function that tries `pbcopy`, then `xclip`, then `wl-copy` would future-proof this.

---

## 3. Help Text

### What works well

- **The header comments are excellent.** Every script has a clear usage block with multiple examples showing different invocation styles (inline, piped, interactive). This is genuinely better than most CLI tools I've seen.
- **`ai-organize --help` is the standout.** Proper flag descriptions, clean layout. This is the model for the others to follow.
- **Interactive fallbacks are smart UX.** When no args are given, tools like `ai-cmd`, `ai-duck`, and `ai-narrative` drop into a `gum input` prompt instead of printing usage and exiting. This is friendlier than a wall of text.

### Issues to address

**3.1 — Most tools have no `--help` flag**
Only `ai-organize` and `ai-search` (implicitly, via the no-args path) print usage information when invoked with `--help`. The rest will either treat `--help` as input to the LLM or ignore it. Adding a simple `--help|-h` case to each script's argument handling would bring them in line.

For the simpler tools (`ai-cmd`, `ai-explain`, `ai-narrative`, `ai-slide-copy`, `ai-duck`), even a minimal block would help:

```bash
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
  sed -n '2,/^[^#]/{ s/^# *//; /^$/q; p; }' "${BASH_SOURCE[0]}"
  exit 0
}
```

This prints the comment header as help text — zero maintenance cost since the comments are already well-written.

**3.2 — Command names are inconsistent between Nix wrappers and Makefile**
The Nix wrapper installs `git-ai-commit`, but the Makefile target is `make git`. The script comment says `gaic`. A user (even you, six months from now) might not remember which name to use. The Makefile's `help` target should list the AI commands and their installed names.

**3.3 — No discoverability mechanism across the suite**
There's no `ai-help` or `ai --list` that shows all available tools and what they do. You have 10+ commands in the `ai-*` namespace — a simple index command would help:

```
ai-help

  Git        git-ai-commit    Generate conventional commit messages
             ai-pr            Generate GitHub PR descriptions

  Generate   ai-cmd           Natural language → shell command
             ai-explain       Explain a command or error
             ai-narrative     Data → report prose
             ai-slide-copy    Data → slide content

  Data       ai-duck          Ask questions about data files (DuckDB)
             ai-organize      Reorganize, rename, deduplicate files

  Search     ai-search        Semantic local search (index + query)
             ai-chat          RAG chat over indexed codebase
```

**3.4 — `pyinit` and `report-init` have no `--help`**
These are the most complex interactive tools, and they have no way to see what they do without running them. The script comments describe the behavior, but those aren't exposed to the user.

**3.5 — `ollama-pull` doesn't document which models or why**
The script pulls three specific models but doesn't explain the mapping (qwen3.5:9b for chat, lfm2.5-thinking for reasoning, qwen3-embedding for search). Adding a brief comment or `--help` output would help you remember why each model was chosen if you revisit this later.

**3.6 — Environment variable overrides are undocumented**
Every tool supports `OLLAMA_MODEL`, `OLLAMA_MODEL_EMBED`, and `AIPR_BASE` overrides, but these aren't mentioned in any help text. A "Configuration" section in each tool's help would surface these.

---

## Summary

| Area | Grade | Rationale |
|------|-------|-----------|
| Error handling | B+ | Guards are thorough, but silent curl failures and the infinite Ollama loop are real risks |
| Output formatting | A- | Cohesive and polished; `ai-organize` is best-in-class; minor inconsistencies across tools |
| Help text | B | Great inline comments, but no `--help` on most tools and no cross-suite discoverability |

### Top 5 changes I'd prioritize

1. **Add a timeout to the Ollama wait loop** — prevents hung terminals (all scripts)
2. **Fix the `ai-commit` case-match spacing bug** — the edit option is silently broken right now
3. **Add `--help` to every tool** — use the comment-header extraction trick for zero maintenance
4. **Create an `ai-help` index command** — one place to see everything available
5. **Surface curl/API errors instead of swallowing them** — makes debugging LLM failures much faster
