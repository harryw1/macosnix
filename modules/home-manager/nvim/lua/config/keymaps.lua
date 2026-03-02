-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

-- Diagnostic Toggle
map("n", "<leader>ud", function() LazyVim.toggle.diagnostics() end, { desc = "Toggle Diagnostics", icon = "󰒓" })

-- Terminal
map("n", "<leader>tt", function() LazyVim.terminal.open() end, { desc = "Terminal (root dir)", icon = "󰞷" })
map("n", "<leader>tT", function() LazyVim.terminal.open(nil, { cwd = vim.uv.cwd() }) end, { desc = "Terminal (cwd)", icon = "󰞷" })
map("n", "<leader>tf", function() LazyVim.terminal.open(nil, { border = "rounded" }) end, { desc = "Floating Terminal", icon = "󱂬" })
