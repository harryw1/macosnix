{ pkgs, ... }:

{
  # ── User packages ──────────────────────────────────────────────────────────
  home.packages = with pkgs; [
    # Modern unix replacements
    bat          # cat with syntax highlighting
    eza          # modern ls
    fd           # fast find
    fzf          # fuzzy finder
    ripgrep      # fast grep (rg)

    # Git toolchain
    git-lfs      # large file storage
    lazygit      # TUI git client

    # Development
    bun          # JavaScript runtime & toolkit
    neovim       # text editor
    gh           # GitHub CLI
    cmake
    duckdb
    uv           # Modern Python toolchain manager
    ty           # Astral's Rust-based Python type checker
    direnv       # Per-directory environment auto-activation
    nix-direnv   # Nix-aware direnv integration
    just         # Task runner (project-level Makefile alternative)
    watchexec    # File watcher for re-running commands on change

    # Data / docs / monitoring
    imagemagick
    marksman     # Markdown LSP
    markdownlint-cli2 # Markdown linter
    prettier     # Formatter
    glow         # Markdown TUI previewer
    typos        # Fast spellchecker
    nmap
    fastfetch
    ruff         # Python linter/formatter
    jq

    # Claude Code
    claude-code
    claude-code-acp
  ];
}
