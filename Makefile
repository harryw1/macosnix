# Nix Darwin — convenience targets
# Usage: make <target>
#
# Override the host for a different machine:
#   make switch HOST=other-machine

HOST ?= aristotle
NIX  := nix --extra-experimental-features 'nix-command flakes'

.PHONY: bootstrap switch build check update update-nixpkgs update-brew gc diff fmt help

bootstrap: ## First-time activation (use before darwin-rebuild is on PATH)
	sudo $(NIX) run nix-darwin -- switch --flake ".#$(HOST)"

switch: ## Apply configuration (activates immediately)
	sudo darwin-rebuild switch --flake ".#$(HOST)"

build: ## Dry-run — evaluate and build without activating
	darwin-rebuild build --flake ".#$(HOST)"

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
