# MacOS Nix Configuration

A declarative MacOS system configuration using nix-darwin and home-manager.

## Prerequisites

- macOS with Nix installed
- For Apple Silicon: `aarch64-darwin`
- For Intel: `x86_64-darwin`

## Installation

1. Install Nix (if not already installed):
```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

2. Enable flakes support (add to `~/.config/nix/nix.conf`):
```
experimental-features = nix-command flakes
```

3. Update configuration values in `flake.nix`:
   - Change `system` to your architecture (aarch64-darwin or x86_64-darwin)
   - Change `hostname` to your Mac's hostname
   - Change `username` to your username

4. Apply configuration:
```bash
nix run nix-darwin -- switch --flake .
```

## Structure

```
.
├── flake.nix              # Flake configuration and inputs
├── modules/
│   ├── system/            # nix-darwin system configuration
│   └── home-manager/      # home-manager user configuration
└── README.md
```

## Usage

To rebuild after making changes:
```bash
darwin-rebuild switch --flake .
```

To update inputs:
```bash
nix flake update
```

## Resources

- [nix-darwin Documentation](https://github.com/lnl7/nix-darwin)
- [home-manager Manual](https://nix-community.github.io/home-manager/)
- [NixOS Wiki - macOS](https://wiki.nixos.org/wiki/NixOS_on_macOS)

## Next Steps

1. Customize `modules/system/default.nix` for system-level settings
2. Customize `modules/home-manager/default.nix` for user packages and dotfiles
3. Add additional modules as needed
4. Test with `nix flake check`
