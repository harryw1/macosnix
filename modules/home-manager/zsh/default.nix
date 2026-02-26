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

    historySubstringSearch = {
      enable = true;
      searchUpKey = [ "^[[A" ];
      searchDownKey = [ "^[[B" ];
    };

    shellAliases = {
      ls  = "eza --icons --group-directories-first";
      ll  = "eza --icons --group-directories-first -l";
      la  = "eza --icons --group-directories-first --git -la";
      cat = "bat";
      lg  = "lazygit";
    };

    plugins = [
      {
        name = "zsh-completions";
        src = pkgs.zsh-completions;
      }
    ];

    initContent = ''
      # Custom zsh initialization
    '';
  };
}
