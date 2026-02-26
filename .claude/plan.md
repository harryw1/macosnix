# Nix Flake Restructure Plan

## Summary

Restructure the existing flake into a well-organized, modular layout. Add
`nix-homebrew` to bootstrap Homebrew via Nix. Fix deprecated home-manager
options. Add sensible macOS defaults with commented-out options throughout
so the collect-script output can be selectively added.

## File changes

### Modified
- `flake.nix` — add nix-homebrew inputs; use `mkDarwinSystem` helper with
  `specialArgs` so hostname/username flow through to all modules; makes
  adding more machines easy later.
- `modules/system/default.nix` — becomes a thin importer of sub-modules;
  sets `networking.hostName`, `system.stateVersion`, trusted-users.
- `modules/home-manager/default.nix` — fix two deprecated zsh options
  (`enableAutosuggestions` → `autosuggestion.enable`,
  `enableSyntaxHighlighting` → `syntaxHighlighting.enable`); wire up
  `home.username`/`home.homeDirectory` from `specialArgs`; add starship.

### Created
- `modules/system/defaults.nix` — all `system.defaults.*` (dock, finder,
  NSGlobalDomain, screencapture, trackpad, keyboard). Most options kept
  as commented examples.
- `modules/system/homebrew.nix` — nix-homebrew activation + the
  `homebrew { }` block with `onActivation.cleanup = "zap"` so the
  installed set stays in sync with what's declared.
- `modules/system/packages.nix` — system packages, nix substituter cache
  config, font packages slot.

## nix-homebrew approach

Three flake inputs are added:
```
nix-homebrew   github:zhaofengli-wip/nix-homebrew
homebrew-core  github:homebrew/homebrew-core/master   (flake = false)
homebrew-cask  github:homebrew/homebrew-cask/master   (flake = false)
```
The taps are declared as flake inputs and wired into the nix-homebrew
module so `nix flake update` keeps them in lock-step. A `taps` attrset
in `homebrew.nix` maps them to the flake inputs.

## Key design decisions
- `specialArgs = { inherit self hostname username; }` propagates identity
  through every module without extra boilerplate.
- `onActivation.cleanup = "zap"` means anything not listed in the nix
  config gets removed on `darwin-rebuild switch`. Easy to change to
  `"uninstall"` (less aggressive) or `"none"`.
- Nix binary cache entries for `cache.nixos.org` and
  `nix-community.cachix.org` added to speed up builds.
- home-manager `home.stateVersion` bumped to `"24.11"`.
- `system.stateVersion = 5` (current nix-darwin).
