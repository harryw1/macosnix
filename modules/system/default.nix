{ config, pkgs, hostname, username, ... }:

{
  imports = [
    ./defaults.nix
    ./homebrew.nix
    ./packages.nix
  ];

  # Set the machine hostname declaratively
  networking.hostName = hostname;

  # Current stable value for nix-darwin — bump this when nix-darwin's changelog
  # says a new stateVersion is required after upgrading.
  system.stateVersion = 5;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Allow the primary user to run nix commands without sudo
    trusted-users = [ "root" username ];
  };

  # Enable Touch ID for sudo authentication
  security.pam.enableSudoTouchIdAuth = true;

  # nix-darwin needs zsh enabled at the system level for home-manager's
  # per-user zsh config to work correctly
  programs.zsh.enable = true;

  # Allow managing fonts through Nix — add font packages here or in packages.nix
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono  # uncomment to manage JetBrains Mono via Nix
  ];
}
