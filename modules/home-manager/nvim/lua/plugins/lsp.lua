return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}

      -- Markdown LSP
      opts.servers.marksman = {}

      -- YAML LSP with SchemaStore for frontmatter validation (Hugo, Jekyll, etc.)
      local ok, schemastore = pcall(require, "schemastore")
      opts.servers.yamlls = {
        settings = {
          yaml = {
            schemaStore = { enable = false, url = "" }, -- use SchemaStore.nvim instead
            schemas = ok and schemastore.yaml.schemas() or {},
          },
        },
      }

      return opts
    end,
  },
}
