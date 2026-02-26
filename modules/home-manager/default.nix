{ config, pkgs, username, ... }:

{
  home.username = username;
  home.homeDirectory = "/Users/${username}";

  # Bump this to the latest home-manager release when upgrading.
  # Do NOT change this to an older value — it's a one-way migration marker.
  home.stateVersion = "24.11";

  # ── User packages ──────────────────────────────────────────────────────────
  home.packages = with pkgs; [
    # Modern unix replacements
    bat          # cat with syntax highlighting
    eza          # modern ls
    fd           # fast find
    fzf          # fuzzy finder
    ripgrep      # fast grep (rg)
    gum          # shell scripting TUI components

    # Git toolchain
    git-delta    # better diffs (wired into programs.git below)
    git-lfs      # large file storage
    lazygit      # TUI git client

    # Development
    neovim       # text editor (see programs.neovim for declarative plugin mgmt)
    gh           # GitHub CLI
    cmake
    duckdb

    # Data / docs / monitoring
    imagemagick
    pandoc
    nmap
    fastfetch
    btop
    ruff         # Python linter/formatter
    jq
  ];

  # ── Zsh ────────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    history = {
      size = 10000;
      ignoreAllDups = true;
    };

    shellAliases = {
      ls  = "eza";
      ll  = "eza -la";
      la  = "eza -la --git";
      cat = "bat";
      lg  = "lazygit";
    };

    initContent = ''
      # Add any custom zsh initialization here
    '';
  };

  # ── Starship prompt ────────────────────────────────────────────────────────
  programs.starship = {
    enable = true;
    # settings = {
    #   add_newline = false;
    #   character = { success_symbol = "[›](bold green)"; };
    # };
  };

  # ── Git ────────────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    userName = "Your Name";
    userEmail = "your.email@example.com";

    delta = {
      enable = true;
      options = {
        navigate = true;
        line-numbers = true;
        side-by-side = false;
      };
    };

    # extraConfig = {
    #   init.defaultBranch = "main";
    #   pull.rebase = true;
    #   push.autoSetupRemote = true;
    #   core.editor = "nvim";
    # };
  };

  # ── Home files ─────────────────────────────────────────────────────────────
  home.file = {
    # ".config/nvim".source = ./nvim;
    # ".config/ghostty/config".source = ./ghostty/config;
  };

  # ── Environment variables ──────────────────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "nvim";
    PAGER  = "bat";
  };
}
