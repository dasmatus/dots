set -U fish_greeting

# Auto-start X on tty1 login
if status is-login
    startx 
end
neofetch -d NixOS
starship init fish | source
alias cat="bat --paging=never"
alias ls="eza -lhi --git --icons"

# bun
set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH
set --export PAGER "$(command -v nvim) +Man!"
set --export DOTNET_ROOT "/home/linuxbrew/.linuxbrew/opt/dotnet/libexec"
export PATH="$HOME/.local/bin:$PATH"

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"


# Added by Antigravity CLI installer
set -gx PATH "/home/matus/.local/bin" $PATH
