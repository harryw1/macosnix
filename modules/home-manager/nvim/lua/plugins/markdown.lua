return {
  -- Add table mode for easier editing of markdown tables
  {
    "dhruvasagar/vim-table-mode",
    event = "VeryLazy",
    init = function()
      -- Configure for Pandoc Grid Tables
      vim.g.table_mode_corner = "+"
      vim.g.table_mode_header_fillchar = "="
      -- Move table mode prefix to <leader>mt (Markdown Table) 
      -- so it doesn't conflict with <leader>t (Terminal)
      vim.g.table_mode_map_prefix = "<leader>mt"
    end,
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
}
