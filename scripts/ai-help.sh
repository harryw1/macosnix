#!/usr/bin/env bash
# ai-help — list all available AI CLI tools
set -euo pipefail

cat <<'EOF'
AI CLI Tools — powered by Ollama

  Launcher
    ai                   Interactive tool picker (or: ai <tool> [args])

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
    ai-index             Quick index / reindex current directory
    ai-search            Semantic local search (index + query)
    ai-chat              RAG chat over indexed codebase

  Database
    ai-db                Manage the embeddings database

  Setup
    ai-config            Configure models and thresholds
    ollama-pull          Pull all required Ollama models
    pyinit               Scaffold a new Python project
    report-init          Scaffold a new report / research project

Tip: just run 'ai' for an interactive menu, or 'ai <shortname>' to
skip the menu (e.g., ai cmd, ai search, ai db, ai chat).
EOF
