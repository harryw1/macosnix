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
    $GUM spin --spinner pulse --title "Adding core dev tools (ruff, pyright, pytest)..." -- $UV add --dev ruff pyright pytest

    if [[ "$TEMPLATE" == *"Research"* ]]; then
      $GUM spin --spinner pulse --title "Adding research tools (marimo)..." -- $UV add marimo
    fi

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
uv run pytest
\`\`\`

### Linting & Formatting
\`\`\`bash
uv run ruff check
uv run ruff format
\`\`\`
EOF

    # 8. Configure pyproject.toml
    # Append to the pyproject.toml created by uv init
    cat <<EOF >> pyproject.toml

[tool.ruff]
line-length = 88
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "A", "C4", "SIM", "ARG", "PTH", "RUF"]

[tool.pyright]
include = ["src", "notebooks"]
typeCheckingMode = "standard"
EOF

    # 9. Initialize git
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
