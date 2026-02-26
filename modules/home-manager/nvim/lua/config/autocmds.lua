-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

local function augroup(name)
  return vim.api.nvim_create_augroup("lazyvim_" .. name, { clear = true })
end

-- Markdown and text file specific settings
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("markdown_settings"),
  pattern = { "markdown", "text", "gitcommit" },
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.spelllang = { "en_us" }
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.conceallevel = 2 -- More balanced for editing links vs seeing them
  end,
})

-- Pandoc export keymaps (markdown only)
vim.api.nvim_create_autocmd("FileType", {
  group = augroup("markdown_export"),
  pattern = "markdown",
  callback = function()
    local map = vim.keymap.set
    local opts = { buffer = true, silent = true }

    -- Export to PDF via pandoc
    map("n", "<leader>mep", function()
      local file = vim.fn.expand("%:p")
      local output = vim.fn.expand("%:p:r") .. ".pdf"
      local template = "/Users/harryweiss/Documents/LaTeX Templates/professional-report.tex"
      local stderr = {}
      vim.notify("󰈦 Exporting to PDF (with professional-report template)…", vim.log.levels.INFO)
      
      local cmd = { 
        "pandoc", file, 
        "--pdf-engine=xelatex", 
        "--template=" .. template,
        "--variable", "geometry:margin=1in",
        "--columns=80",
        "-o", output 
      }
      
      vim.fn.jobstart(cmd, {
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line ~= "" then
                table.insert(stderr, line)
              end
            end
          end
        end,
        on_exit = function(_, code)
          if code == 0 then
            vim.notify("󰈦 PDF exported → " .. output, vim.log.levels.INFO)
          else
            local error_msg = "PDF export failed"
            if #stderr > 0 then
              error_msg = error_msg .. ": " .. table.concat(stderr, "\n")
            else
              error_msg = error_msg .. " (is pandoc/xelatex installed?)"
            end
            vim.notify(error_msg, vim.log.levels.ERROR)
          end
        end,
      })
    end, vim.tbl_extend("force", opts, { desc = "Export to PDF" }))

    -- Export to Word (.docx) via pandoc
    map("n", "<leader>mew", function()
      local file = vim.fn.expand("%:p")
      local output = vim.fn.expand("%:p:r") .. ".docx"
      local stderr = {}
      vim.notify("󰈙 Exporting to Word…", vim.log.levels.INFO)
      vim.fn.jobstart({ "pandoc", file, "-o", output }, {
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line ~= "" then
                table.insert(stderr, line)
              end
            end
          end
        end,
        on_exit = function(_, code)
          if code == 0 then
            vim.notify("󰈙 Word doc exported → " .. output, vim.log.levels.INFO)
          else
            local error_msg = "Word export failed"
            if #stderr > 0 then
              error_msg = error_msg .. ": " .. table.concat(stderr, "\n")
            else
              error_msg = error_msg .. " (is pandoc installed?)"
            end
            vim.notify(error_msg, vim.log.levels.ERROR)
          end
        end,
      })
    end, vim.tbl_extend("force", opts, { desc = "Export to Word (.docx)" }))
  end,
})
