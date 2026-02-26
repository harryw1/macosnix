{ inputs, username, ... }:

# ─── Homebrew (managed via nix-homebrew) ──────────────────────────────────────
# nix-homebrew installs and pins Homebrew itself via Nix.
# The `homebrew` block below is nix-darwin's declarative package list.
#
# Rebuild workflow:
#   1. Add/remove brews or casks here
#   2. Run: make switch  (or darwin-rebuild switch --flake .#aristotle)
#   onActivation.cleanup = "zap" removes anything NOT listed here on each switch.
#   Change to "uninstall" if you want a softer cleanup, or "none" to opt out.
#
# WARNING: The first `darwin-rebuild switch` after enabling nix-homebrew will
# migrate your existing Homebrew installation (autoMigrate = true). Anything
# currently installed that isn't listed in brews/casks below will be removed
# once you activate. Add what you need before switching.
# ─────────────────────────────────────────────────────────────────────────────

{
  nix-homebrew = {
    enable = true;
    enableRosetta = true;  # install under Intel prefix too (useful for some casks)
    user = username;
    autoMigrate = true;    # migrate existing /opt/homebrew installation
    taps = {
      "homebrew/homebrew-core" = inputs.homebrew-core;
      "homebrew/homebrew-cask" = inputs.homebrew-cask;
      "nikitabobko/homebrew-tap" = inputs.homebrew-nikitabobko-tap;
    };
    mutableTaps = false;   # taps are read-only; managed exclusively via flake inputs
  };

  homebrew = {
    enable = true;

    onActivation = {
      cleanup = "zap";      # remove unlisted formulae/casks on each rebuild
      autoUpdate = false;   # Nix controls updates via `nix flake update`
      upgrade = false;
    };

    # Note: taps are managed by nix-homebrew above (mutableTaps = false),
    # so no need to list them here — they're already symlinked by nix-homebrew.
    # Only add third-party taps here that aren't in nix-homebrew.taps.

    # ── CLI formulae ──────────────────────────────────────────────────────────
    # Only things that genuinely need Homebrew:
    # - macOS-specific integration (dnsmasq launchd service, ollama Metal/GPU)
    # - version managers that own their own toolchain (rustup)
    # - tools not yet in nixpkgs (gemini-cli)
    # - Python tool management (pipx)
    # Everything else should go in home.packages.
    brews = [
      "dnsmasq"      # local DNS resolver (runs as launchd service via brew services)
      "mas"          # Mac App Store CLI
      "ollama"       # local LLM runner (requires Metal/GPU integration)
      "pipx"         # install Python CLIs in isolated envs (cookiecutter, whisper, etc.)
      "rustup"       # Rust version manager — owns its own toolchain, don't use nixpkgs rust
      "podman"       # container runtime (macOS VM integration)
      "gemini-cli"   # not yet in nixpkgs
    ];

    # ── GUI applications (casks) ──────────────────────────────────────────────
    casks = [
      "alcove"
      "arc"                    # browser
      "cleanshot"
      "discord"
      "firefox"
      "kitty"                  # terminal emulator
      "macwhisper"
      "microsoft-auto-update"
      "microsoft-office"
      "microsoft-teams"
      "obsidian"
      "pixelsnap"
      "raycast"
      "steam"
      "sublime-merge"
      "sublime-text"
      "tailscale-app"
      "teamspeak-client"
      "thebrowsercompany-dia"
    ];

    # ── Mac App Store apps ────────────────────────────────────────────────────
    # Requires `mas` in brews above. Find app IDs with: mas search <name>
    masApps = {
      # "Amphetamine" = 937984704;
    };
  };
}
