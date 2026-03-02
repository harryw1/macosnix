{ ... }:

{
  # ── Modern CLI Tools ───────────────────────────────────────────────────────
  programs.bat.enable = true;
  programs.fzf.enable = true;
  programs.dircolors.enable = true;
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
    options = [ "--cmd cd" ];
  };
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
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
