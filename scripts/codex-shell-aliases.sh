# Codex parallel-agent aliases
#
# Source this from ~/.zshrc or ~/.bashrc:
#   source /path/to/repo/scripts/codex-shell-aliases.sh

alias startct='codex-start-parallel tmux'
alias startcc='codex-start-parallel cmux'
alias joinct='join-parallel --mux tmux codex-$(basename "$PWD")'
alias joincc='join-parallel --mux cmux'
