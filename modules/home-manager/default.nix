{ config, pkgs, username, flavor ? "frappe", ... }:

{
  imports = [
    ./git
    ./kitty
    ./starship
    ./zsh
  ];

  home.username = username;
  home.homeDirectory = "/Users/${username}";

  # Bump this to the latest home-manager release when upgrading.
  # Do NOT change this to an older value — it's a one-way migration marker.
  home.stateVersion = "24.11";

  # ── Catppuccin Theme ────────────────────────────────────────────────────────
  catppuccin.flavor = flavor;
  catppuccin.enable = true;

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
    nmap
    fastfetch
    btop
    ruff         # Python linter/formatter
    jq
  ];

  # ── Modern CLI Tools ───────────────────────────────────────────────────────
  programs.bat.enable = true;
  programs.fzf.enable = true;
  programs.eza = {
    enable = true;
    git = true;
    icons = "auto";
  };

  programs.lazygit = {
    enable = true;
  };

  # ── Home files ─────────────────────────────────────────────────────────────
  home.file = {
    ".config/nvim" = {
      source = ./nvim;
      recursive = true;
    };
    ".config/nvim/lua/plugins/colorscheme.lua".text = ''
      return {
        {
          "catppuccin/nvim",
          name = "catppuccin",
          priority = 1000,
          opts = {
            flavour = "${flavor}",
            transparent_background = true,
            show_end_of_buffer = false, -- keep it clean
            term_colors = true,
            dim_inactive = {
              enabled = false,
            },
            float = {
              transparent = true,
            },
            integrations = {
              aerial = true,
              alpha = true,
              cmp = true,
              dashboard = true,
              flash = true,
              gitsigns = true,
              headlines = true,
              illuminate = true,
              indent_blankline = { enabled = true },
              leap = true,
              lsp_trouble = true,
              mason = true,
              markdown = true,
              mini = true,
              native_lsp = {
                enabled = true,
                underlines = {
                  errors = { "undercurl" },
                  hints = { "undercurl" },
                  warnings = { "undercurl" },
                  information = { "undercurl" },
                },
              },
              navic = { enabled = true, custom_bg = "NONE" },
              neotest = true,
              neotree = true,
              noice = true,
              notify = true,
              semantic_tokens = true,
              telescope = true,
              treesitter = true,
              treesitter_context = true,
              which_key = true,
            },
          },
        },
        {
          "LazyVim/LazyVim",
          opts = {
            colorscheme = "catppuccin-${flavor}",
          },
        },
      }
    '';
  };

  # ── Environment variables ──────────────────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "nvim";
    PAGER  = "bat";
  };
}
