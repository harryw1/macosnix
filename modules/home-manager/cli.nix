{ ... }:

{
  # ── Modern CLI Tools ───────────────────────────────────────────────────────
  programs.bat.enable = true;
  programs.fzf.enable = true;
  programs.eza = {
    enable = true;
    git = true;
    icons = "auto";
  };

  programs.lazygit = {
    enable = true;
  };
}
