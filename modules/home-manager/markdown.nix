{ ... }:

{
  # ── Global Markdown Linting Configuration ────────────────────────────────
  # Using .markdownlint-cli2.jsonc as it is the preferred format for modern markdownlint
  home.file.".markdownlint-cli2.jsonc".text = ''
    {
      "config": {
        "default": true,
        "MD013": false,
        "MD025": false,
        "MD033": false,
        "MD051": false
      }
    }
  '';

  # Add standard .markdownlint.json for tools that prefer it
  home.file.".markdownlint.json".text = ''
    {
      "default": true,
      "MD013": false,
      "MD025": false,
      "MD033": false,
      "MD051": false
    }
  '';
}
