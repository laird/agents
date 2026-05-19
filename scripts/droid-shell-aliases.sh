# Droid parallel-agent aliases
#
# Source this from ~/.zshrc or ~/.bashrc:
#   source /path/to/repo/scripts/droid-shell-aliases.sh

alias startdt='start-parallel --mux tmux --agent droid'
alias startdc='start-parallel --mux cmux --agent droid'
alias joindt='join-parallel --mux tmux droid-$(basename "$PWD")'
alias joindc='join-parallel --mux cmux'
