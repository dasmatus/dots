set -U fish_greeting

# Auto-start X on tty1 login
if status is-login
    startx
end

# Nix
if test -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
end
neofetch -d NixOS
starship init fish | source
alias cat="bat --paging=never"
alias ls="eza -lhi --git --icons"

# Claude Code with Ultracode (multi-agent orchestration) on for the whole session.
# Ultracode has no launch flag, so we inject a standing opt-in via the system prompt.
alias claude-ultra="claude --append-system-prompt 'Ultracode is ON for this entire session (standing opt-in). For every substantive task, author and run a Workflow (multi-agent orchestration) by default instead of working solo: decompose, fan out parallel agents, and adversarially verify findings before reporting. Token cost is not a constraint — favor thoroughness. Handle only trivial, conversational, or purely mechanical turns solo.'"

# bun
set --export BUN_INSTALL "$HOME/.bun"
set --export PATH $BUN_INSTALL/bin $PATH
set --export PAGER "$(command -v nvim) +Man!"
set --export DOTNET_ROOT "/home/linuxbrew/.linuxbrew/opt/dotnet/libexec"
export PATH="$HOME/.local/bin:$PATH"

eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv fish)"


# Added by Antigravity CLI installer
set -gx PATH "/home/matus/.local/bin" $PATH
