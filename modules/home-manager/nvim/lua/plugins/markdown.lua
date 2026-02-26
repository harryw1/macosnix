return {
  -- Add table mode for easier editing of markdown tables
  {
    "dhruvasagar/vim-table-mode",
    event = "VeryLazy",
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
      { "<leader>mp", "<cmd>PasteImage<cr>", desc = "Paste image from clipboard" },
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
      file_types = { "markdown" },
      -- Enable rendering for wide tables
      heading = {
        enabled = true,
        sign = true,
        icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " },
      },
    },
  },
}
