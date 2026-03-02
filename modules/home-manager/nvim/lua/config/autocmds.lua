-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

local function augroup(name)
  return vim.api.nvim_create_augroup("lazyvim_" .. name, { clear = true })
end

-- Common prose settings (spell, wrap, linebreak) for text-like filetypes
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("prose_settings"),
  pattern = { "markdown", "text", "gitcommit" },
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.spelllang = { "en_us" }
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
  end,
})

-- Markdown-only: conceal links/syntax for cleaner editing
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("markdown_settings"),
  pattern = "markdown",
  callback = function()
    vim.opt_local.conceallevel = 2
  end,
})

-- Pandoc export keymaps (markdown only)
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("markdown_export"),
  pattern = "markdown",
  callback = function()
    local map = vim.keymap.set
    local opts = { buffer = true, silent = true }
    local filter   = vim.env.HOME .. "/.pandoc/filters/callouts.lua"

    -- Shared async pandoc helper
    local function pandoc_export(args, label, icon)
      local stderr = {}
      vim.notify(icon .. " Exporting to " .. label .. "…", vim.log.levels.INFO)
      vim.fn.jobstart(args, {
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line ~= "" then table.insert(stderr, line) end
            end
          end
        end,
        on_exit = function(_, code)
          if code == 0 then
            vim.notify(icon .. " " .. label .. " exported → " .. args[#args], vim.log.levels.INFO)
          else
            local msg = label .. " export failed"
            if #stderr > 0 then
              msg = msg .. ": " .. table.concat(stderr, "\n")
            else
              msg = msg .. " (is pandoc installed?)"
            end
            vim.notify(msg, vim.log.levels.ERROR)
          end
        end,
      })
    end

    -- Export to PDF via pandoc + xelatex
    map("n", "<leader>mep", function()
      local file = vim.fn.expand("%:p")
      local output = vim.fn.expand("%:p:r") .. ".pdf"
      pandoc_export({
        "pandoc", file,
        "--pdf-engine=xelatex",
        "--template=professional-report",
        "--lua-filter=" .. filter,
        "--columns=80",
        "-o", output,
      }, "PDF", "󰈦")
    end, vim.tbl_extend("force", opts, { desc = "Export to PDF" }))

    -- Export to Word (.docx) via pandoc
    map("n", "<leader>mew", function()
      local file = vim.fn.expand("%:p")
      local output = vim.fn.expand("%:p:r") .. ".docx"
      pandoc_export({ "pandoc", file, "-o", output }, "Word (.docx)", "󰈙")
    end, vim.tbl_extend("force", opts, { desc = "Export to Word (.docx)" }))

    -- Export to standalone HTML file via pandoc
    map("n", "<leader>meh", function()
      local file = vim.fn.expand("%:p")
      local output = vim.fn.expand("%:p:r") .. ".html"
      pandoc_export({ "pandoc", file, "--standalone", "-o", output }, "HTML", "󰌨")
    end, vim.tbl_extend("force", opts, { desc = "Export to HTML" }))

    -- Render to HTML and copy to system clipboard (useful for Notion, email, etc.)
    map("n", "<leader>mec", function()
      local file = vim.fn.expand("%:p")
      local chunks = {}
      local stderr = {}
      vim.notify("󰆏 Copying HTML to clipboard…", vim.log.levels.INFO)
      vim.fn.jobstart({ "pandoc", file, "--standalone" }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          vim.list_extend(chunks, data)
        end,
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line ~= "" then table.insert(stderr, line) end
            end
          end
        end,
        on_exit = function(_, code)
          if code == 0 then
            local html = table.concat(chunks, "\n")
            local pbcopy = vim.fn.jobstart({ "pbcopy" }, { stdin = "pipe" })
            vim.fn.chansend(pbcopy, html)
            vim.fn.chanclose(pbcopy, "stdin")
            vim.notify("󰆏 HTML copied to clipboard", vim.log.levels.INFO)
          else
            local msg = "HTML clipboard copy failed"
            if #stderr > 0 then msg = msg .. ": " .. table.concat(stderr, "\n") end
            vim.notify(msg, vim.log.levels.ERROR)
          end
        end,
      })
    end, vim.tbl_extend("force", opts, { desc = "Copy HTML to clipboard" }))
  end,
})
