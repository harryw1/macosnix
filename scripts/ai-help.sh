#!/usr/bin/env bash
# ai-help — list all available AI CLI tools
set -euo pipefail

cat <<'EOF'
AI CLI Tools — powered by Ollama

  Git
    git-ai-commit        Generate conventional commit messages
    ai-pr                Generate GitHub PR descriptions

  Generate
    ai-cmd               Natural language → shell command
    ai-explain           Explain a command or error message
    ai-narrative         Data / metrics → report prose
    ai-slide-copy        Data / metrics → slide content

  Data
    ai-duck              Ask questions about data files (DuckDB)
    ai-organize          Reorganize, rename, deduplicate files

  Search
    ai-search            Semantic local search (index + query)
    ai-chat              RAG chat over indexed codebase

  Setup
    ollama-pull          Pull all required Ollama models
    pyinit               Scaffold a new Python project
    report-init          Scaffold a new report / research project

Run any command with --help for usage details and env var overrides.
EOF
