{ pkgs, ... }:

{
  # ── Zsh ────────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    history = {
      size = 10000;
      ignoreAllDups = true;
    };

    shellAliases = {
      ls  = "eza";
      ll  = "eza -la";
      la  = "eza -la --git";
      cat = "bat";
      lg  = "lazygit";
    };

    plugins = [
      {
        name = "zsh-completions";
        src = pkgs.zsh-completions;
      }
      {
        name = "zsh-history-substring-search";
        src = pkgs.zsh-history-substring-search;
      }
    ];

    initContent = ''
      # Custom zsh initialization
      bindkey '^[[A' history-substring-search-up
      bindkey '^[[B' history-substring-search-down
    '';
  };
}
