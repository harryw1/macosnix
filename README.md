# macosnix

Declarative macOS system configuration using nix-darwin and home-manager.

## First-time setup

### 1. Install Nix

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Restart your terminal after installation so `nix` is on your PATH.

### 2. Clone this repository

```bash
git clone <repo-url> ~/macosnix
cd ~/macosnix
```

### 3. Personalise before activating

**`flake.nix`** — update the `darwinConfigurations` block with your machine details:

```nix
"aristotle" = mkDarwinSystem {
  hostname = "your-hostname";   # find yours: scutil --get LocalHostName
  username = "you";             # find yours: whoami
};
```

**`modules/home-manager/default.nix`** — fill in your git identity:

```nix
programs.git = {
  userName  = "Your Name";
  userEmail = "you@example.com";
};
```

### 4. Bootstrap

`darwin-rebuild` is not on your PATH yet on a fresh system. Use the bootstrap
target, which calls `nix run nix-darwin` to activate everything in one step:

```bash
make bootstrap
```

This installs nix-darwin, applies the full configuration, and sets up
Homebrew and home-manager. It can take a while on first run.

### 5. Done

After bootstrap, `darwin-rebuild` is available. All future changes go through:

```bash
make switch
```

## Targets

```
make bootstrap        First-time activation (before darwin-rebuild is on PATH)
make switch           Apply configuration (activates immediately)
make build            Dry-run — evaluate and build without activating
make diff             Show what switch would change (requires nvd)
make update           Update all flake inputs
make update-nixpkgs   Update only nixpkgs
make update-brew      Update homebrew-core and homebrew-cask taps
make gc               Remove old generations and garbage collect
make fmt              Format all Nix files
make check            Validate the flake
```

Run `make help` for a quick summary at any time.

## Structure

```
.
├── flake.nix                    # Inputs, machine definitions
├── flake.lock                   # Pinned dependency versions
├── Makefile                     # Convenience targets
└── modules/
    ├── system/
    │   ├── default.nix          # Hostname, Nix settings, Touch ID, shell, fonts
    │   ├── defaults.nix         # macOS system preferences (Dock, Finder, keyboard…)
    │   ├── homebrew.nix         # Homebrew formulae and casks
    │   └── packages.nix         # System packages and Nix binary caches
    └── home-manager/
        └── default.nix          # User packages, shell, git, environment variables
```

## Adding a second machine

Call `mkDarwinSystem` again in `flake.nix`:

```nix
darwinConfigurations = {
  "aristotle" = mkDarwinSystem { hostname = "aristotle"; username = "harryweiss"; };
  "plato"     = mkDarwinSystem { hostname = "plato";     username = "harryweiss"; };
};
```

Then bootstrap on the new machine with:

```bash
make bootstrap FLAKE=.#plato
```

## Resources

- [nix-darwin](https://github.com/nix-darwin/nix-darwin)
- [home-manager manual](https://nix-community.github.io/home-manager/)
- [Determinate Nix installer](https://determinate.systems/posts/determinate-nix-installer/)
- [nix-darwin option search](https://mynixos.com/nix-darwin/options)
- [home-manager option search](https://mynixos.com/home-manager/options)
