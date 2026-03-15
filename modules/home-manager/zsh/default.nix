{ pkgs, flavor, ... }:

let
  # Define overlay0 color for each flavor to use in zsh-autosuggestions
  overlay0 = {
    latte     = "#9ca0b0";
    frappe    = "#737994";
    macchiato = "#6e738d";
    mocha     = "#6c7086";
  }."${flavor}";
in
{
  # ── Zsh ────────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion = {
      enable = true;
      highlight = "fg=${overlay0}";
    };
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    history = {
      size = 50000;
      ignoreAllDups = true;
      ignoreSpace = true;
    };

    historySubstringSearch = {
      enable = true;
      searchUpKey = [ "^[[A" "^P" ];
      searchDownKey = [ "^[[B" "^N" ];
    };

    shellAliases = {
      ls   = "eza --icons --group-directories-first";
      ll   = "eza --icons --group-directories-first -l";
      la   = "eza --icons --group-directories-first --git -la";
      lt   = "eza --icons --tree --group-directories-first";
      cat  = "bat";
      v    = "nvim";
      vi   = "nvim";
      vim  = "nvim";
      grep = "rg";
      find = "fd";
      cc   = "claude";

      # ── Git & Git-AI ───────────────────────────────────────────────────────
      g    = "git";
      ga   = "git add";
      gaa  = "git add --all";
      gs   = "git status";
      gd   = "git diff";
      gb   = "git branch";
      gco  = "git checkout";
      gc   = "git commit -m";
      gl   = "git pull";
      gp   = "git push";
      lg   = "lazygit";
      gac  = "git-ai-commit"; # AI-generated commit message (ollama)
      gapr = "ai-pr";         # AI-generated PR description


      # ── Navigation ────────────────────────────────────────────────────────
      ".."   = "cd ..";
      "..."  = "cd ../..";
      "...." = "cd ../../..";

      # ── Python & Astral Toolchain ──────────────────────────────────────────
      py    = "python";
      uvp   = "uv python";
      uvr   = "uv run";
      rff   = "ruff format";
      rfc   = "ruff check --fix";
      # ty is now installed directly (pkgs.ty) — no alias needed
      nb    = "uvx marimo edit";  # Start marimo notebook editor (via uvx)
      ipy   = "uvx ipython";  # Enhanced interactive Python REPL (via uvx)
      j     = "just";          # Shorthand for justfile tasks
      wt    = "watchexec";    # Watch files and re-run commands on change
      ri    = "report-init";  # Scaffold a research / report project

      # ── AI Tools (ollama) ────────────────────────────────────────────────
      ol     = "ollama-pull";  # One-step model setup
      aih    = "ai-help";      # List all ai-* tools
      aie    = "ai-explain";   # Explain a command or error
      aicmd  = "ai-cmd";       # Natural language → shell command
      aichat = "ai-chat";      # RAG chat over indexed codebase
      aix    = "ai-index";     # Quick index / reindex current directory
      ais    = "ai-search";    # Semantic file search
      ain    = "ai-narrative"; # Data → report prose
      aid    = "ai-duck";      # Ask questions about data files (DuckDB)
      aisc   = "ai-slide-copy"; # Data → slide copy
      aio    = "ai-organize";  # AI file reorganizer / renamer / deduplicator
      
      # ── Data & System ─────────────────────────────────────────────────────
      duck  = "duckdb";        # DuckDB CLI
      bt    = "btop";          # System monitor
      ff    = "fastfetch";     # System info

      # ── Markdown conversion (mdconvert: python-docx + WeasyPrint) ────────────
      # Report style (navy/gold palette, cover page)
      md2docx = "mdconvert -f docx";       # md2docx report.md  → report.docx
      md2pdf  = "mdconvert -f pdf";        # md2pdf  report.md  → report.pdf
      md2html = "mdconvert -f html";       # md2html report.md  → report.html
      # Meeting-notes style (clean black/grey, no cover page)
      md2notes      = "mdconvert -f docx -t notes";
      md2notes-pdf  = "mdconvert -f pdf  -t notes";
      md2notes-html = "mdconvert -f html -t notes";
    };

    plugins = [
      {
        name = "zsh-completions";
        src = pkgs.zsh-completions;
      }
      {
        name = "zsh-fzf-tab";
        src = pkgs.zsh-fzf-tab;
        file = "share/fzf-tab/fzf-tab.plugin.zsh";
      }
      {
        name = "zsh-nix-shell";
        src = pkgs.zsh-nix-shell;
        file = "share/zsh/plugins/zsh-nix-shell/nix-shell.plugin.zsh";
      }
    ];

    initContent = builtins.readFile ./init.zsh;
  };
}
