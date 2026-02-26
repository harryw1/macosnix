# Nix Darwin — convenience targets
# Usage: make <target>
#
# Override the flake target for a different machine:
#   make switch FLAKE=.#other-machine

FLAKE ?= .#aristotle
NIX   := nix --extra-experimental-features 'nix-command flakes'

.PHONY: switch build check update update-nixpkgs update-brew gc diff fmt help

switch: ## Apply configuration (activates immediately)
	darwin-rebuild switch --flake $(FLAKE)

build: ## Dry-run — evaluate and build without activating
	darwin-rebuild build --flake $(FLAKE)

check: ## Check the flake evaluates without errors
	$(NIX) flake check

diff: build ## Show what switch would change (requires nvd)
	nvd diff /run/current-system result

update: ## Update all flake inputs
	$(NIX) flake update

update-nixpkgs: ## Update only nixpkgs
	$(NIX) flake update nixpkgs

update-brew: ## Update homebrew-core and homebrew-cask taps
	$(NIX) flake update homebrew-core homebrew-cask

gc: ## Remove old generations and run garbage collection
	nix-collect-garbage -d
	$(NIX) store optimise

fmt: ## Format all Nix files (requires nixfmt-rfc-style)
	$(NIX) run nixpkgs#nixfmt-rfc-style -- flake.nix $$(find modules -name '*.nix')

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
