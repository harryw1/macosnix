{
  description = "macOS system configuration (nix-darwin + home-manager)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    # Declarative tap management — pinned in flake.lock for reproducibility.
    # Run `nix flake update homebrew-core homebrew-cask` to pull new formulae/casks.
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
  };

  outputs = inputs @ { self, nix-darwin, nixpkgs, home-manager, nix-homebrew, ... }:
    let
      # Helper to define a Darwin system. Add more machines to darwinConfigurations
      # below by calling mkDarwinSystem with different hostname/username values.
      mkDarwinSystem =
        { hostname
        , username
        , system ? "aarch64-darwin"  # change to "x86_64-darwin" for Intel
        }:
        nix-darwin.lib.darwinSystem {
          inherit system;
          # specialArgs threads hostname, username, and all flake inputs through
          # to every module so they never need to import from the flake root.
          specialArgs = { inherit self inputs hostname username; };
          modules = [
            ./modules/system
            nix-homebrew.darwinModules.nix-homebrew
            home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.${username} = import ./modules/home-manager;
              home-manager.extraSpecialArgs = { inherit username; };
            }
          ];
        };
    in
    {
      darwinConfigurations = {
        "aristotle" = mkDarwinSystem {
          hostname = "aristotle";
          username = "harryweiss";
        };
      };
    };
}
