{ config, pkgs, username, flavor ? "frappe", ... }:

{
  imports = [
    ./cli.nix
    ./git
    ./kitty
    ./nvim
    ./packages.nix
    ./starship
    ./zsh
    ./markdown.nix
  ];

  home.username = username;
  home.homeDirectory = "/Users/${username}";

  # Bump this to the latest home-manager release when upgrading.
  # Do NOT change this to an older value — it's a one-way migration marker.
  home.stateVersion = "24.11";

  # ── Catppuccin Theme ────────────────────────────────────────────────────────
  catppuccin.flavor = flavor;
  catppuccin.enable = true;

  # ── Environment variables ──────────────────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "nvim";
    PAGER  = "bat";
  };
}
