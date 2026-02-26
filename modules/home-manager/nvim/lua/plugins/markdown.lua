return {
  -- Configure markdownlint-cli2 rules via nvim-lint
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      opts.linters = opts.linters or {}
      opts.linters["markdownlint-cli2"] = {
        prepend_args = { "--config", vim.fn.stdpath("config") .. "/markdownlint.yaml" },
      }
      return opts
    end,
  },

  -- Add table mode for easier editing of markdown tables
  {
    "dhruvasagar/vim-table-mode",
    event = "VeryLazy",
    init = function()
      -- Configure for Pandoc Grid Tables
      vim.g.table_mode_corner = "+"
      vim.g.table_mode_header_fillchar = "="
      -- Disable default mappings to prevent messy which-key display
      vim.g.table_mode_disable_mappings = 1
    end,
    keys = {
      { "<leader>mt", "<cmd>TableModeToggle<cr>", desc = "Toggle Table Mode" },
      { "<leader>mre", "<cmd>TableModeRealign<cr>", desc = "Realign Table" },
    },
  },

  -- Add image pasting capability
  {
    "HakonHarnes/img-clip.nvim",
    event = "VeryLazy",
    opts = {
      default = {
        dir_path = "assets", -- store images in an assets/ folder relative to the markdown file
        prompt_for_file_name = true,
      },
    },
    keys = {
      { "<leader>mp", "<cmd>PasteImage<cr>", desc = "󰏶 Paste image from clipboard" },
    },
  },

  -- Obsidian support (requires a vault path)
  -- {
  --   "epwalsh/obsidian.nvim",
  --   version = "*",
  --   lazy = true,
  --   ft = "markdown",
  --   dependencies = { "nvim-lua/plenary.nvim" },
  --   opts = {
  --     workspaces = {
  --       { name = "vault", path = "~/Documents/Notes" },
  --     },
  --   },
  -- },

  -- Configure render-markdown.nvim if needed
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = {
      -- Enable rendering for wide tables
      heading = {
        enabled = true,
        sign = true,
        icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " },
      },
    },
  },

  -- Add <leader>mv as a markdown-group alias for the browser preview
  -- (LazyVim's markdown extra already sets <leader>cp for the same command)
  {
    "iamcco/markdown-preview.nvim",
    keys = {
      { "<leader>mv", "<cmd>MarkdownPreviewToggle<cr>", ft = "markdown", desc = " Toggle Preview" },
    },
  },
}
