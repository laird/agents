# Claude Code parallel-agent aliases
#
# Source this from ~/.zshrc or ~/.bashrc:
#   source /path/to/repo/scripts/claude-shell-aliases.sh

alias startclt='start-parallel --mux tmux --agent claude'
alias startclc='start-parallel --mux cmux --agent claude'
alias joinclt='join-parallel --mux tmux claude-$(basename "$PWD")'
alias joinclc='join-parallel --mux cmux'
