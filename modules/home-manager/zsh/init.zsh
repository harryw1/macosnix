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

# Auto-activate .venv
function _auto_activate_venv() {
    if [[ -d .venv && -f .venv/bin/activate ]]; then
        # Only activate if it's not already active or if it's a different one
        if [[ "$VIRTUAL_ENV" != "$PWD/.venv" ]]; then
            source .venv/bin/activate
        fi
    elif [[ -n "$VIRTUAL_ENV" ]]; then
        # Deactivate if we moved out of the venv's root directory
        # The parent directory of the .venv folder is the project root
        local venv_root="${VIRTUAL_ENV%/.venv}"
        if [[ "$PWD" != "$venv_root"* ]]; then
            deactivate
        fi
    fi
}

autoload -U add-zsh-hook
add-zsh-hook chpwd _auto_activate_venv
_auto_activate_venv

# Custom zsh initialization
