# Nix Darwin — convenience targets
# Usage: make <target>
#
# Override the host for a different machine:
#   make switch HOST=other-machine

HOST ?= aristotle
NIX  := nix --extra-experimental-features 'nix-command flakes'

.PHONY: bootstrap check-rosetta switch build check update update-nixpkgs update-brew gc diff fmt help

bootstrap: check-rosetta ## First-time activation (use before darwin-rebuild is on PATH)
	sudo $(NIX) run nix-darwin -- switch --flake ".#$(HOST)"

check-rosetta: ## Ensure Rosetta 2 is installed before setting up the Intel Homebrew prefix
	@if [ "$$(uname -m)" = "arm64" ]; then \
		if ! pkgutil --pkg-info=com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then \
			echo "Rosetta 2 is not installed. Installing (required for Intel Homebrew prefix)..."; \
			sudo softwareupdate --install-rosetta --agree-to-license || { \
				echo "ERROR: Rosetta 2 installation failed. Run 'softwareupdate --install-rosetta' manually and retry."; \
				exit 1; \
			}; \
		fi \
	fi

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
