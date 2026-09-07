# Vault-backed git credentials over SSH. rbw (unofficial Bitwarden CLI;
# bitwarden.com is its default server, so no base_url/identity_url) plus
# its built-in SSH agent ($XDG_RUNTIME_DIR/rbw/ssh-agent-socket, rbw >=
# 1.15) serves the vault-held ed25519 key for BOTH transport auth
# (push/pull to codeberg.org/dasmatus/dots over SSH) and SSH commit
# signing (git.nix). No PAT, no forge CLI, no HTTPS credential helper:
# the repo is public, so the first-login clone is anonymous HTTPS and
# everything after is SSH. No private key or token ever lands in the
# world-readable Nix store or in git. GNOME's gcr-ssh-agent is disabled
# in nix/modules/desktop/desktop.nix so the rbw agent owns SSH_AUTH_SOCK.
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
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:

let
  # The Bitwarden account email is NOT assumed to equal the git or Proton
  # address — three separate accounts. It comes from settings (empty by
  # default) rather than the literal that used to sit here: this is a public
  # repo, and an address written into it is in the clone history for good.
  # Empty means the key is omitted from rbw's config entirely and rbw prompts
  # on first use. See nix/system/defaults.nix's "eval-time identity" block for
  # why this is a settings key and not an agenix secret — rbw's config.json is
  # generated at evaluation, which agenix cannot reach.
  bitwardenEmail = settings.bitwardenEmail;

  # The signing identity written into allowed_signers is read at RUNTIME from
  # the decrypted agenix secret, not from the Nix config: since
  # nix/home/shell/git.nix stopped setting user.email (it arrives through an
  # `[include]`, see nix/home/secrets/identity.nix), there is no eval-time
  # value left to interpolate — `config.programs.git.settings.user.email`
  # would now be null. `git config --get` resolves the include chain the same
  # way every other git command does, so this picks up the decrypted address.
  gitConfigGet = "${pkgs.git}/bin/git config --get user.email";
  pubkeyFile = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
  # Mirrors nix/home/base/dots-repo.nix's repoRel — the legacy "gitlab" segment
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
    signer_email="$(${gitConfigGet} || true)"
    if [ -z "$signer_email" ]; then
      echo "dots-keys: git user.email is unset — the agenix git-identity secret is missing or undecrypted, so allowed_signers cannot be written (see nix/home/secrets/identity.nix)" >&2
      exit 1
    fi
    printf '%s %s\n' "$signer_email" \
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
  # Enabled only when an address is configured, and gated at `programs.rbw`
  # rather than inside `settings`. home-manager's rbw module declares
  # `settings.email` with NO default, so leaving it out is not "absent from
  # config.json" — it is an evaluation error ("The option
  # `programs.rbw.settings.email' was accessed but has no value defined") the
  # moment the module renders that file. There is no way to express
  # "unconfigured" from inside `settings`; the only lever is the module itself.
  #
  # Which is also the behaviour worth having. A config.json carrying
  # `"email": ""` is worse than no config.json at all: rbw reads it as the
  # configured account and stops prompting, leaving the vault permanently
  # unreachable. With the module off there is simply no config, and `rbw
  # login` asks for the address on first use. dots-keys below is unaffected —
  # it calls `${pkgs.rbw}/bin/rbw` by absolute store path, so it never depended
  # on this module to put the binary anywhere.
  programs.rbw = lib.mkIf (bitwardenEmail != "") {
    enable = true;
    settings = {
      email = bitwardenEmail;
      # gcr's system prompter; its dbus service already ships via
      # gnome-keyring (GNOME in nix/modules/desktop/desktop.nix), so the rbw
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

  # Second contribution to the shared `dots` plugin identity declared in
  # beamenu.nix (alongside `keybinds`); nix list options merge by
  # concatenation, so both commands land in the same manifest.
}
