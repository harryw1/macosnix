{ ... }:

{
  # ── LaTeX / Pandoc Templates ────────────────────────────────────────────────
  # Templates are deployed to ~/.pandoc/templates/ so pandoc can find them by
  # name:  pandoc doc.md --template professional-report -o doc.pdf
  #
  # All templates are XeLaTeX + pandoc-variable aware.  Edit the .tex files in
  # this directory and run `darwin-rebuild switch` to update.

  home.file.".pandoc/templates/professional-report.tex".source = ./professional-report.tex;
  home.file.".pandoc/templates/meeting-notes.tex".source       = ./meeting-notes.tex;

  # preamble.tex is also deployed for manual \input use in ad-hoc documents
  home.file.".pandoc/templates/preamble.tex".source = ./preamble.tex;

  # Lua filter: converts [!WARNING] alerts → tcolorbox, strips redundant H1
  home.file.".pandoc/filters/callouts.lua".source = ./callouts.lua;
}
