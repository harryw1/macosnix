return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        marksman = {},
        -- Specific config for markdownlint if used via LSP
        markdownlint = {
          settings = {
            config = {
              default = true,
              MD013 = false, -- Line length
              MD025 = false, -- Multiple H1
              MD033 = false, -- Inline HTML
            },
          },
        },
      },
    },
  },
}
