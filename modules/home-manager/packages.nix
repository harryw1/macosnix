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
    neovim       # text editor
    gh           # GitHub CLI
    cmake
    duckdb

    # Data / docs / monitoring
    imagemagick
    pandoc
    marksman     # Markdown LSP
    markdownlint-cli2 # Markdown linter
    prettier     # Formatter
    glow         # Markdown TUI previewer
    typos        # Fast spellchecker
    nmap
    fastfetch
    btop
    ruff         # Python linter/formatter
    jq
  ];
}
