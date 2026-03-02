return {
  "greggh/claude-code.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("claude-code").setup({
      window = {
        position = "vertical",
        split_ratio = 0.4,
        enter_insert = true,
        hide_numbers = true,
        hide_signcolumn = true,
      },
      git = {
        use_git_root = true,
      },
      file_refresh = {
        enable = true,
        show_notifications = true,
      },
    })
  end,
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude Code" },
    { "<leader>aR", "<cmd>ClaudeCodeResume<cr>", desc = "Resume Claude conversation" },
  },
}
