{ pkgs, flavor, ... }:

let
  # Define overlay0 color for each flavor to use in zsh-autosuggestions
  overlay0 = {
    latte     = "#9ca0b0";
    frappe    = "#737994";
    macchiato = "#6e738d";
    mocha     = "#6c7086";
  }."${flavor}";
in
{
  # ── Zsh ────────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion = {
      enable = true;
      highlight = "fg=${overlay0}";
    };
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    history = {
      size = 10000;
      ignoreAllDups = true;
    };

    historySubstringSearch = {
      enable = true;
      searchUpKey = [ "^[[A" "^P" ];
      searchDownKey = [ "^[[B" "^N" ];
    };

    shellAliases = {
      ls   = "eza --icons --group-directories-first";
      ll   = "eza --icons --group-directories-first -l";
      la   = "eza --icons --group-directories-first --git -la";
      cat  = "bat";
      lg   = "lazygit";
      v    = "nvim";
      vi   = "nvim";
      vim  = "nvim";
      grep = "rg";

      # Markdown conversion (Pandoc)
      # md2pdf file.md -> file.pdf using professional-report.tex
      md2pdf = "pandoc --pdf-engine=xelatex --template='/Users/harryweiss/Documents/LaTeX Templates/professional-report.tex' --variable geometry:margin=1in --columns=80 -o";
      
      # md2docx file.md -> file.docx
      md2docx = "pandoc --columns=80 -o";
    };

    plugins = [
      {
        name = "zsh-completions";
        src = pkgs.zsh-completions;
      }
      {
        name = "zsh-fzf-tab";
        src = pkgs.zsh-fzf-tab;
        file = "share/fzf-tab/fzf-tab.plugin.zsh";
      }
      {
        name = "zsh-nix-shell";
        src = pkgs.zsh-nix-shell;
        file = "share/zsh/plugins/zsh-nix-shell/nix-shell.plugin.zsh";
      }
    ];

    initContent = builtins.readFile ./init.zsh;
  };
}
