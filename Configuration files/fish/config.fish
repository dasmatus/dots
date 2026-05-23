set -U fish_greeting
neofetch -d NixOS
starship init fish | source
alias cat=bat
alias ls="eza -lhi --git --icons"


# bun
set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH
export PATH="$HOME/.local/bin:$PATH"
