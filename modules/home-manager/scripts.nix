{ pkgs, ... }:

let
  pyinit = pkgs.writeShellScriptBin "pyinit" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Interactive Python project scaffolding using uv and gum
    GUM="${pkgs.gum}/bin/gum"
    UV="${pkgs.uv}/bin/uv"

    # 1. Get Project Name
    PROJECT_NAME="''${1:-}"
    if [ -z "$PROJECT_NAME" ]; then
      PROJECT_NAME=$($GUM input --placeholder "Project Name (e.g., my-awesome-tool)")
    fi

    if [ -z "$PROJECT_NAME" ]; then
      echo "❌ Project name is required."
      exit 1
    fi

    # 2. Choose Template
    TEMPLATE=$($GUM choose --header "Select project template" "Library (src-layout)" "Data & Research (marimo-focused)")

    # 2b. Ask about entry point
    ADD_ENTRYPOINT=false
    if $GUM confirm --default=false "Add a main.py entry point? (enables \`uv run main.py\`)"; then
      ADD_ENTRYPOINT=true
    fi

    # 3. Setup Project Directory
    if [ -d "$PROJECT_NAME" ]; then
        if ! $GUM confirm "Directory $PROJECT_NAME already exists. Overwrite?"; then
            exit 1
        fi
    fi
    mkdir -p "$PROJECT_NAME"
    cd "$PROJECT_NAME" || exit

    # 4. Initialize uv project
    case "$TEMPLATE" in
      "Library (src-layout)")
        $GUM spin --spinner dot --title "Initializing Library..." -- $UV init --lib
        ;;
      "Data & Research (marimo-focused)")
        $GUM spin --spinner dot --title "Initializing Research project..." -- $UV init --app
        mkdir -p data notebooks
        ;;
    esac

    # 5. Add standard dev dependencies
    $GUM spin --spinner pulse --title "Adding core dev tools (ruff, pyright, pytest, pytest-cov, pre-commit)..." -- $UV add --dev ruff pyright pytest pytest-cov pre-commit

    if [[ "$TEMPLATE" == *"Research"* ]]; then
      $GUM spin --spinner pulse --title "Adding research tools (marimo)..." -- $UV add marimo
    fi

    # 5.5 Prepare the virtual environment
    $GUM spin --spinner pulse --title "Syncing dependencies and preparing .venv..." -- $UV sync

    # 6. Create robust .gitignore
    cat <<EOF > .gitignore
__pycache__/
*.py[cod]
.venv/
.env
.DS_Store
dist/
build/
*.egg-info/
.ipynb_checkpoints/
.marimo/
.pytest_cache/
.ruff_cache/
EOF

    # 7. Auto-populate README.md
    CURRENT_DATE=$(date +"%Y-%m-%d")
    USER_NAME=$(git config user.name || echo "Developer")

    cat <<EOF > README.md
# $PROJECT_NAME

Scaffolded on: $CURRENT_DATE
By: $USER_NAME

## Overview
Briefly describe the purpose of $PROJECT_NAME.

## Development
This project uses \`uv\` for dependency and environment management.

### Setup
\`\`\`bash
uv sync
\`\`\`

### Testing
\`\`\`bash
uv run pytest || [ $? -eq 5 ] && echo "No tests found — write some tests!" && exit 0
\`\`\`

### Linting & Formatting
\`\`\`bash
uv run ruff check
uv run ruff format
\`\`\`
EOF

    # 8. Configure pyproject.toml
    # Append to the pyproject.toml created by uv init
    if [[ "$TEMPLATE" == *"Research"* ]]; then
      PYRIGHT_INCLUDE='["src", "notebooks"]'
    else
      PYRIGHT_INCLUDE='["src"]'
    fi

    cat <<EOF >> pyproject.toml

[tool.ruff]
line-length = 88
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "A", "C4", "SIM", "ARG", "PTH", "RUF"]

[tool.pyright]
include = $PYRIGHT_INCLUDE
typeCheckingMode = "standard"

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]

[tool.coverage.run]
source = ["src"]
omit = ["tests/*"]

[tool.coverage.report]
show_missing = true
skip_covered = false
EOF

    # 8b. For library projects, scaffold src module, data, and tests
    if [[ "$TEMPLATE" == *"Library"* ]]; then
      # Derive the importable package name (hyphens → underscores)
      PKG_NAME=$(echo "$PROJECT_NAME" | tr '-' '_')
      mkdir -p tests

      # Overwrite __init__.py: explicit re-export + __all__
      if [ "$ADD_ENTRYPOINT" = true ]; then
        cat <<EOF > src/$PKG_NAME/__init__.py
"""$PROJECT_NAME - add a short description here."""

from .core import greet as greet
from .core import main as main

__all__ = ["greet", "main"]
EOF
      else
        cat <<EOF > src/$PKG_NAME/__init__.py
"""$PROJECT_NAME - add a short description here."""

from .core import greet as greet

__all__ = ["greet"]
EOF
      fi

      # Create core.py: typed function in its own submodule
      cat <<EOF > src/$PKG_NAME/core.py
"""Core functionality for $PROJECT_NAME."""


def greet(name: str) -> str:
    """Return a greeting for the given name."""
    return f"Hello, {name}!"
EOF

      if [ "$ADD_ENTRYPOINT" = true ]; then
        cat <<EOF >> src/$PKG_NAME/core.py


def main() -> None:
    """Application entry point."""
    print(greet("world"))
EOF
      fi

      # Create data directory with a sample CSV
      mkdir -p data
      cat <<EOF > data/sample.csv
name,value
alice,1
bob,2
charlie,3
EOF

      # conftest.py: data_dir fixture anchored to the project root
      cat <<EOF > tests/conftest.py
from pathlib import Path

import pytest


@pytest.fixture
def data_dir() -> Path:
    """Return path to the project-level data/ directory."""
    return Path(__file__).parent.parent / "data"
EOF

      # Starter tests: package import, submodule import, re-export, data loading
      cat <<EOF > tests/test_$PKG_NAME.py
import csv
from pathlib import Path

import $PKG_NAME
from $PKG_NAME import greet                     # re-exported via __init__
from $PKG_NAME.core import greet as core_greet  # direct submodule import


def test_package_importable() -> None:
    assert $PKG_NAME is not None


def test_greet_via_init() -> None:
    assert greet("world") == "Hello, world!"


def test_greet_via_submodule() -> None:
    assert core_greet("nix") == "Hello, nix!"


def test_re_export_on_package() -> None:
    # greet is accessible on the package object via __init__ re-export
    assert $PKG_NAME.greet("lib") == "Hello, lib!"


def test_read_sample_csv(data_dir: Path) -> None:
    csv_path = data_dir / "sample.csv"
    assert csv_path.exists(), f"Expected data file at {csv_path}"
    with csv_path.open() as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 3
    assert rows[0]["name"] == "alice"
EOF

      # Create main.py and register CLI script entry point
      if [ "$ADD_ENTRYPOINT" = true ]; then
        cat <<EOF > main.py
"""Entry point for $PROJECT_NAME."""

from $PKG_NAME import main

if __name__ == "__main__":
    main()
EOF

        cat <<EOF >> pyproject.toml

[project.scripts]
$PROJECT_NAME = "$PKG_NAME:main"
EOF
      fi
    fi

    # 9. Generate justfile with standard project tasks
    cat <<EOF > justfile
# List available tasks
default:
    @just --list

# Run all checks (format, lint, typecheck, test)
all: fmt lint typecheck test

# Format code
fmt:
    uv run ruff format .

# Lint and auto-fix
lint:
    uv run ruff check --fix .

# Type-check
typecheck:
    uv run pyright

# Run tests
test:
    uv run pytest || { code=\$?; [ \$code -eq 5 ] && echo "No tests found — write some tests!" && exit 0; exit \$code; }

# Run tests with coverage report
cov:
    uv run pytest --cov --cov-report=term-missing

# Run pre-commit hooks on all files
pc:
    uv run pre-commit run --all-files
EOF

    if [ "$ADD_ENTRYPOINT" = true ]; then
      cat <<EOF >> justfile

# Run the application
run:
    uv run main.py
EOF
    fi

    # 10. Generate pre-commit config
    cat <<EOF > .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: ruff-check
        name: ruff check
        entry: uv run ruff check --fix
        language: system
        types: [python]
      - id: ruff-format
        name: ruff format
        entry: uv run ruff format
        language: system
        types: [python]
EOF

    # 11. Initialize git
    git init -q
    git add .
    git commit -m "Initial commit (scaffolded by pyinit)" -q

    echo ""
    $GUM style --foreground 212 --border-foreground 212 --border double --padding "1 2" --margin "1 2" "✅ Project $PROJECT_NAME ($TEMPLATE) ready!"
  '';

  # ── mdconvert: markdown → docx / html / pdf (python-docx + WeasyPrint) ──────
  # Replaces the fragile pandoc table pipeline.
  # The Python script lives next to this file; uv resolves its inline deps on
  # first run (cached thereafter under ~/.cache/uv).
  mdconvert = pkgs.writeShellScriptBin "mdconvert" ''
    exec ${pkgs.uv}/bin/uv run "${./mdconvert.py}" "$@"
  '';

  # Thin wrapper: the real logic lives in scripts/git-ai-commit.sh so that
  # `make git` can call it directly (before `make switch` has been run) while
  # this nix-installed binary makes `gaic` available system-wide afterwards.
  git-ai-commit = pkgs.writeShellScriptBin "git-ai-commit" ''
    exec bash "${../../scripts/git-ai-commit.sh}" "$@"
  '';

  ai-explain = pkgs.writeShellScriptBin "ai-explain" ''
    exec bash "${../../scripts/ai-explain.sh}" "$@"
  '';

  ai-pr = pkgs.writeShellScriptBin "ai-pr" ''
    exec bash "${../../scripts/ai-pr.sh}" "$@"
  '';

  ollama-pull = pkgs.writeShellScriptBin "ollama-pull" ''
    #!/usr/bin/env bash
    # Pull models for Ollama

    # Check if Ollama is running
    if ! pgrep -x "Ollama" > /dev/null; then
      echo "Ollama is not running. Starting Ollama.app..."
      open -a Ollama
      # Wait for Ollama to start
      echo "Waiting for Ollama to start..."
      while ! curl -s http://localhost:11434/api/tags > /dev/null; do
        sleep 1
      done
    fi

    echo "Pulling qwen3.5:9b (Chat)..."
    ollama pull qwen3.5:9b

    echo "Pulling lfm2.5-thinking:1.2b (Reasoning)..."
    ollama pull lfm2.5-thinking:1.2b

    echo "Pulling qwen3-embedding:8b (Embedding)..."
    ollama pull qwen3-embedding:8b
  '';
in
{
  home.packages = [
    pyinit
    ollama-pull
    mdconvert
    git-ai-commit
    ai-explain
    ai-pr
  ];
}
