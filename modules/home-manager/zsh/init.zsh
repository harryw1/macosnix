# ── Man pages via bat ────────────────────────────────────────────────────────
export MANPAGER="sh -c 'col -bx | bat -l man -p'"
export MANROFFOPT="-c"

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
# preview file contents or directory listings for all other completions
zstyle ':fzf-tab:complete:*:*' fzf-preview 'bat --color=always --style=numbers $realpath 2>/dev/null || eza -1 --color=always $realpath 2>/dev/null'
# preview process info when completing kill
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview '[[ $group == "[process ID]" ]] && ps -p $word -o pid,ppid,user,comm'
# switch group using `<` and `>`
zstyle ':fzf-tab:*' switch-group ',' '.'

# Custom zsh initialization

# Fix just completions: show usage signature instead of full recipe source
functions[_just]="${functions[_just]//just --show \$recipe/just --usage \$recipe}"

# Create a directory and immediately enter it
mkcd() { mkdir -p "$1" && cd "$1" }
