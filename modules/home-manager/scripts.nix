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
      cat <<EOF > src/$PKG_NAME/__init__.py
"""$PROJECT_NAME - add a short description here."""

from .core import greet as greet

__all__ = ["greet"]
EOF

      # Create core.py: typed function in its own submodule
      cat <<EOF > src/$PKG_NAME/core.py
"""Core functionality for $PROJECT_NAME."""


def greet(name: str) -> str:
    """Return a greeting for the given name."""
    return f"Hello, {name}!"
EOF

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
in
{
  home.packages = [
    pyinit
  ];
}
