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
        -- Keymap icons (registered here, not in keymap opts)
        { "<leader>ac", icon = "󱙺" },
        { "<leader>aR", icon = "󰄉" },
        { "<leader>ud", icon = "󰒓" },
        { "<leader>tt", icon = "󰞷" },
        { "<leader>tT", icon = "󰞷" },
        { "<leader>tf", icon = "󱂬" },
      },
    },
  },
}
