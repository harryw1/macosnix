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
    (texlive.combine {
      inherit (texlive) 
        scheme-small
        geometry
        tools
        fontspec
        microtype
        xcolor
        hyperref
        xurl
        parskip
        enumitem
        graphics
        booktabs
        multirow
        wrapfig
        float
        colortbl
        pdflscape
        pdfcol
        tabu
        ltablex
        threeparttable
        threeparttablex
        ulem
        makecell
        xltabular
        etoolbox
        ragged2e
        amsfonts
        amsmath
        tcolorbox
        fancyhdr
        titlesec
        tocloft
        environ
        pgf
        tikzfill
        tabularray
        setspace
        caption
        mathspec # often used with xelatex
        ;
    })
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
