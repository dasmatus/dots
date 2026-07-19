# Vault-backed git credentials over SSH. rbw (unofficial Bitwarden CLI;
# bitwarden.com is its default server, so no base_url/identity_url) plus
# its built-in SSH agent ($XDG_RUNTIME_DIR/rbw/ssh-agent-socket, rbw >=
# 1.15) serves the vault-held ed25519 key for BOTH transport auth
# (push/pull to codeberg.org/dasmatus/dots over SSH) and SSH commit
# signing (git.nix). No PAT, no forge CLI, no HTTPS credential helper:
# the repo is public, so the first-login clone is anonymous HTTPS and
# everything after is SSH. No private key or token ever lands in the
# world-readable Nix store or in git. GNOME's gcr-ssh-agent is disabled
# in nix/modules/desktop.nix so the rbw agent owns SSH_AUTH_SOCK.
#
# One-time imperative step this module cannot do for you: run `dots-keys`
# once after first login. It unlocks/logs in rbw (master password + 2FA
# via the gcr pinentry; if bitwarden.com answers with a captcha error,
# run `rbw register` once with the personal API key from the web vault's
# security settings, then re-run), syncs the vault, exports the vault SSH
# key's public half to ~/.ssh/id_ed25519.pub (git's signingkey), writes
# ~/.config/git/allowed_signers, and ensures the dots repo's Codeberg
# remote is on SSH. Safe to re-run. Prerequisite in the vault: an
# SSH-key-type item (created in the web vault/app — rbw serves keys, it
# cannot create them).
#
# One-time-EVER (per vault key, not per machine — the key is shared
# across all your hosts): upload ~/.ssh/id_ed25519.pub to Codeberg's
# Settings → SSH/GPG keys, marked for auth AND signing (Forgejo verifies
# SSH-signed commits). Until then SSH push/pull fail; the public HTTPS
# clone still works.
#
# Day-to-day UX: the agent is spawned on demand by any rbw command and
# starts *locked* — after a reboot, run `rbw unlock` before the first
# push or signed commit (lock_timeout re-locks after an hour). Deliberate
# trade-off for a key that never touches disk. Escape hatch while
# un-bootstrapped: `git -c commit.gpgsign=false commit`.
{ config, pkgs, ... }:

let
  # User-owned values — not derivable from the repo. The Bitwarden account
  # email is NOT assumed to equal the git/proton address.
  bitwardenEmail = "Shadiness9530@pm.me";

  gitEmail = config.programs.git.settings.user.email;
  pubkeyFile = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
  # Mirrors nix/home/dots-repo.nix's repoRel — the legacy "gitlab" segment
  # is just a folder name now; the repo lives on codeberg.org/dasmatus/dots.
  dotsRepo = "${config.home.homeDirectory}/Dokumente/gitlab/personal/dots";
  codebergSsh = "ssh://git@codeberg.org/dasmatus/dots";

  dotsKeys = pkgs.writeShellScriptBin "dots-keys" ''
    set -euo pipefail

    # The login shell that runs this may predate this config's session vars.
    export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR}/rbw/ssh-agent-socket"

    if ! ${pkgs.rbw}/bin/rbw unlocked > /dev/null 2>&1; then
      ${pkgs.rbw}/bin/rbw unlock || ${pkgs.rbw}/bin/rbw login
    fi
    ${pkgs.rbw}/bin/rbw sync

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    keys="$(${pkgs.openssh}/bin/ssh-add -L || true)"
    if [ -z "$keys" ]; then
      echo "dots-keys: no SSH keys in the vault — create an SSH-key item in the Bitwarden web vault first" >&2
      exit 1
    fi
    if [ "$(printf '%s\n' "$keys" | wc -l)" -gt 1 ]; then
      echo "dots-keys: vault serves multiple SSH keys, using the first" >&2
    fi
    printf '%s\n' "$keys" | head -n 1 > "${pubkeyFile}"

    mkdir -p "$HOME/.config/git"
    printf '%s %s\n' "${gitEmail}" \
      "$(${pkgs.gawk}/bin/awk '{ print $1 " " $2 }' "${pubkeyFile}")" \
      > "$HOME/.config/git/allowed_signers"

    # Keep the dots repo's Codeberg remote on SSH so push/pull ride the
    # vault key. Flip any existing remote already pointing at codeberg.org
    # to SSH; add a 'codeberg' remote if none does. A non-codeberg remote
    # (e.g. a legacy gitlab origin) is never touched. set-url only records
    # the URL — no connection, safe before the key is unlocked.
    if [ -d "${dotsRepo}/.git" ]; then
      found=0
      for r in $(${pkgs.git}/bin/git -C "${dotsRepo}" remote); do
        case "$(${pkgs.git}/bin/git -C "${dotsRepo}" remote get-url "$r")" in
          *codeberg.org/dasmatus/dots*)
            ${pkgs.git}/bin/git -C "${dotsRepo}" remote set-url "$r" "${codebergSsh}"
            found=1
            ;;
        esac
      done
      if [ "$found" = 0 ]; then
        ${pkgs.git}/bin/git -C "${dotsRepo}" remote add codeberg "${codebergSsh}"
      fi
    fi

    echo "dots-keys: vault SSH agent + commit signing ready; Codeberg remote on SSH."
    echo "dots-keys: one-time-ever — upload ~/.ssh/id_ed25519.pub to Codeberg (Settings → SSH/GPG keys) as auth + signing."
    echo "dots-keys: after a reboot, run 'rbw unlock' before the first push or signed commit."
  '';
in
{
  programs.rbw = {
    enable = true;
    settings = {
      email = bitwardenEmail;
      # gcr's system prompter; its dbus service already ships via
      # gnome-keyring (GNOME in nix/modules/desktop.nix), so the rbw
      # module's services.dbus.packages warning does not apply here.
      pinentry = pkgs.pinentry-gnome3;
    };
  };

  # No systemd unit for rbw-agent: it self-daemonizes and is spawned on
  # demand by the first rbw command, which fights systemd's cgroup
  # lifetime tracking for no gain — a unit could not remove the unlock
  # prompt anyway.
  home.sessionVariables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/rbw/ssh-agent-socket";

  home.packages = [ dotsKeys ];
}