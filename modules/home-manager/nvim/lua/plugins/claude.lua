return {
  "greggh/claude-code.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("claude-code").setup({
      window = {
        position = "right",
        size = 0.4,
      },
    })
  end,
  keys = {
    { "<leader>ac", "<cmd>ClaudeCodeToggle<cr>", desc = "Toggle Claude Code" },
  },
}
