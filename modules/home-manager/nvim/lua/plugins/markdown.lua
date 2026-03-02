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

  -- Table editing with Pandoc Grid Table style
  {
    "dhruvasagar/vim-table-mode",
    event = "VeryLazy",
    init = function()
      vim.g.table_mode_corner = "+"
      vim.g.table_mode_header_fillchar = "="
      vim.g.table_mode_disable_mappings = 1
    end,
    keys = {
      { "<leader>mt", "<cmd>TableModeToggle<cr>", desc = "Toggle Table Mode" },
      { "<leader>mr", "<cmd>TableModeRealign<cr>", desc = "Realign Table" },
    },
  },

  -- Image pasting from clipboard
  {
    "HakonHarnes/img-clip.nvim",
    event = "VeryLazy",
    opts = {
      default = {
        dir_path = "assets",
        prompt_for_file_name = true,
      },
    },
    keys = {
      { "<leader>mp", "<cmd>PasteImage<cr>", desc = "Paste image from clipboard" },
    },
  },

  -- Obsidian-style wiki links, backlinks, and [[link]] completion
  {
    "epwalsh/obsidian.nvim",
    version = "*",
    lazy = true,
    ft = "markdown",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      workspaces = {
        { name = "notes", path = vim.env.HOME .. "/Documents/Notes" },
      },
      -- Use marksman for completion; obsidian.nvim adds [[link]] support on top
      completion = { nvim_cmp = false },
    },
  },

  -- In-buffer markdown rendering
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = {
      heading = {
        enabled = true,
        sign = true,
        icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " },
      },
      code     = { enabled = true },
      bullet   = { enabled = true },
      checkbox = { enabled = true },
      quote    = { enabled = true },
      dash     = { enabled = true },
      link     = { enabled = true },
      -- GitHub-style alert rendering ([!NOTE], [!WARNING], etc.)
      callout = {
        note      = { raw = "[!NOTE]",      rendered = "󰋽 Note",      highlight = "RenderMarkdownInfo"    },
        tip       = { raw = "[!TIP]",       rendered = "󰌶 Tip",       highlight = "RenderMarkdownSuccess" },
        important = { raw = "[!IMPORTANT]", rendered = "󰅾 Important", highlight = "RenderMarkdownHint"    },
        warning   = { raw = "[!WARNING]",   rendered = "󰀪 Warning",   highlight = "RenderMarkdownWarn"    },
        caution   = { raw = "[!CAUTION]",   rendered = "󰳦 Caution",   highlight = "RenderMarkdownError"   },
      },
    },
  },

  -- Browser preview
  {
    "iamcco/markdown-preview.nvim",
    keys = {
      { "<leader>mv", "<cmd>MarkdownPreviewToggle<cr>", ft = "markdown", desc = "Toggle Preview" },
    },
  },

  -- YAML schema validation for markdown frontmatter (Hugo, Jekyll, etc.)
  {
    "b0o/SchemaStore.nvim",
    lazy = true,
  },
}
