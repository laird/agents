# Codex parallel-agent aliases
#
# Source this from ~/.zshrc or ~/.bashrc:
#   source /path/to/repo/scripts/codex-shell-aliases.sh

alias startct='start-parallel --mux tmux --agent codex'
alias startcc='start-parallel --mux cmux --agent codex'
alias joinct='join-parallel --mux tmux codex-$(basename "$PWD")'
alias joincc='join-parallel --mux cmux'
