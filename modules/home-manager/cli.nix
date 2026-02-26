{ ... }:

{
  # ── Modern CLI Tools ───────────────────────────────────────────────────────
  programs.bat.enable = true;
  programs.fzf.enable = true;
  programs.dircolors.enable = true;
  programs.zoxide.enable = true;
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
  programs.eza = {
    enable = true;
    git = true;
    icons = "auto";
  };

  programs.lazygit = {
    enable = true;
  };
}
