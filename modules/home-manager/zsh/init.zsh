# fzf-tab configuration
# disable sort when completing `git checkout`
zstyle ':completion:*:git-checkout:*' sort false
# set descriptions format to enable group support
# (needed for fzf-tab to distinguish groups)
zstyle ':completion:*:descriptions' format '[%d]'
# set list-colors to enable filename colorizing
zstyle ':completion:*' list-colors ''${(s.:.)LS_COLORS}
# force zsh not to show completion menu, which allows fzf-tab to capture the request
zstyle ':completion:*' menu no
# preview directory's content with eza when completing cd
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
# switch group using `<` and `>`
zstyle ':fzf-tab:*' switch-group ',' '.'

# Custom zsh initialization

# Auto-activate Python virtual environment when entering a project directory.
# Works with uv's default .venv layout — no .envrc required.
auto_activate_venv() {
  if [[ -f ".venv/bin/activate" ]]; then
    source .venv/bin/activate
  elif [[ -n "$VIRTUAL_ENV" && ! -f ".venv/bin/activate" ]]; then
    deactivate
  fi
}
add-zsh-hook chpwd auto_activate_venv
auto_activate_venv  # also run on shell startup for the initial directory
