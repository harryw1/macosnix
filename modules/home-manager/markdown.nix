{ ... }:

{
  # ── Global Markdown Linting Configuration ────────────────────────────────
  home.file.".markdownlint.json".text = builtins.toJSON {
    "default" = true;
    "MD013" = false; # Disable line length (too annoying for tables)
    "MD025" = false; # Allow multiple top-level headings
    "MD033" = false; # Allow inline HTML (needed for some advanced formatting)
    "MD051" = false; # Disable link fragment check (often trips on partial files)
  };
}
