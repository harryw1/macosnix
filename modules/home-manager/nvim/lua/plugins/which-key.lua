return {
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      spec = {
        -- Groups
        { "<leader>a",  group = "ai",       icon = "󱙺 " },
        { "<leader>m",  group = "markdown",  icon = "󰽛 " },
        { "<leader>me", group = "export",    icon = "󰈧 " },
        { "<leader>t",  group = "terminal",  icon = "󰞷 " },
        { "<leader>u",  group = "ui",        icon = "󰙵 " },
        -- AI keymaps
        { "<leader>ac", icon = "󱙺" },
        { "<leader>aR", icon = "󰄉" },
        -- UI keymaps
        { "<leader>ud", icon = "󰒓" },
        -- Terminal keymaps
        { "<leader>tt", icon = "󰞷" },
        { "<leader>tT", icon = "󰞷" },
        { "<leader>tf", icon = "󱂬" },
        -- Markdown keymaps
        { "<leader>mt", icon = "󱗖" },  -- Toggle Table Mode
        { "<leader>mr", icon = "󰁁" },  -- Realign Table
        { "<leader>mp", icon = "󰏶" },  -- Paste Image
        { "<leader>mv", icon = "" },   -- Toggle Preview
        -- Export keymaps
        { "<leader>mep", icon = "󰈦" }, -- PDF
        { "<leader>mew", icon = "󰈙" }, -- Word
        { "<leader>meh", icon = "󰌨" }, -- HTML file
        { "<leader>mec", icon = "󰆏" }, -- HTML clipboard
      },
    },
  },
}
