# Gemini (Antigravity) parallel-agent aliases
#
# Source this from ~/.zshrc or ~/.bashrc:
#   source /path/to/repo/scripts/gemini-shell-aliases.sh

alias startgt='start-parallel --mux tmux --agent gemini'
alias startgc='start-parallel --mux cmux --agent gemini'
alias joingt='join-parallel --mux tmux gemini-$(basename "$PWD")'
alias joingc='join-parallel --mux cmux'
