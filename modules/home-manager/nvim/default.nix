{ flavor, ... }:

{
  # ── Neovim Configuration ───────────────────────────────────────────────────
  home.file = {
    ".config/nvim" = {
      source = ./.;
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
}
