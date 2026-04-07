# Droid parallel-agent aliases
#
# Source this from ~/.zshrc or ~/.bashrc:
#   source /path/to/repo/scripts/droid-shell-aliases.sh

alias startdt='droid-start-parallel tmux'
alias startdc='droid-start-parallel cmux'
alias joindt='join-parallel --mux tmux droid-$(basename "$PWD")'
alias joindc='join-parallel --mux cmux'
