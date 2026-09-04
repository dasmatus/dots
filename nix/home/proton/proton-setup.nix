# The one-time Proton logins, as a command the settings panel can drive.
#
# nix/home/proton/proton-drive.nix and nix/home/proton/proton-calendar.nix both deliberately
# keep credentials out of Nix: rclone and proton-cli each authenticate once and
# then persist their own session, so nothing has to be stored in the world
# readable store or in /var/lib/dots. The cost of that choice is that setup
# lives in two hand-typed commands. This wraps them so the Proton page in the
# SUPER+comma panel can run them, and can say whether either session is alive.
#
# Secrets arrive on stdin and never become a command argument. Anything in a
# process argument list shows up in `ps` for anyone, and the obscured form
# rclone stores is reversible, so obscuring before passing it would not help.
# `rclone obscure -` takes the password on stdin, and the config section is
# appended here with shell builtins rather than handed to `rclone config
# create`, whose password argument would land in argv.
#
# proton-cli is the exception, and it is a deliberate one: it reads its
# credentials from the environment, so PROTON_PASSWORD is exported for that
# one child. /proc/<pid>/environ is no worse than argv here (both are readable
# by this user and root, and by nobody else on a single-user machine), but it
# is not nothing, and it is why the export is scoped to the branch that needs
# it rather than set at the top of the script.
#
# Two facts about rclone drive the shape below, both established by running it
# rather than by reading the docs:
#
#   - `rclone config create` does not log in. It writes the section, exits 0,
#     and authentication happens lazily on first use. So `connect` has to
#     exercise the remote (`rclone lsd`) before it can claim anything worked.
#   - The `2fa` config key holds a plain TOTP code, which is stale within the
#     minute. It is only ever read on a fresh login, and the cached tokens
#     rclone writes back (client_uid, client_access_token, client_refresh_token,
#     client_salted_key_pass) are what later runs use. The stale code is
#     cleared after a successful login so a future re-auth fails asking for a
#     new one rather than silently retrying a dead one.
#
# `connect` takes one target rather than doing both, because a TOTP code is
# single use: spending it on the Drive login leaves nothing valid for the
# calendar. The page asks for a fresh code per target.
{ pkgs, ... }:
let
  setup = pkgs.writeShellApplication {
    name = "proton-setup";
    runtimeInputs = [
      pkgs.rclone
      pkgs.proton-cli
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      # A configured-but-unreachable remote is not set up, so status probes
      # rather than just grepping the config. The timeout keeps a dead network
      # from hanging the settings panel, which calls this on every open.
      probe_drive() {
        if ! rclone listremotes 2>/dev/null | grep -qx 'protondrive:'; then
          return 1
        fi
        timeout 20 rclone lsd protondrive: >/dev/null 2>&1
      }

      probe_calendar() {
        timeout 20 proton-cli calendar calendars list >/dev/null 2>&1
      }

      cmd=''${1:-}
      case "$cmd" in
        status)
          drive=false
          calendar=false
          probe_drive && drive=true
          probe_calendar && calendar=true
          printf '{"drive":%s,"calendar":%s}\n' "$drive" "$calendar"
          ;;

        connect)
          target=''${2:-}
          # Three lines, in this order. read -r so a backslash in a password
          # is a backslash.
          IFS= read -r email
          IFS= read -r password
          IFS= read -r totp

          if [ -z "$email" ] || [ -z "$password" ]; then
            echo "proton-setup: email and password are both required" >&2
            exit 2
          fi

          case "$target" in
            drive)
              obscured=$(printf '%s' "$password" | rclone obscure -)
              conf=$(rclone config file | tail -1)
              mkdir -p "$(dirname "$conf")"
              touch "$conf"
              chmod 600 "$conf"

              # Replace only our own section. `config delete` on a remote that
              # is not there is not an error worth stopping for, and every
              # other remote in the file is left alone.
              rclone config delete protondrive >/dev/null 2>&1 || true
              {
                printf '\n[protondrive]\n'
                printf 'type = protondrive\n'
                printf 'username = %s\n' "$email"
                printf 'password = %s\n' "$obscured"
                printf '2fa = %s\n' "$totp"
              } >> "$conf"

              # The login actually happens here, not above.
              if ! timeout 120 rclone lsd protondrive: >/dev/null; then
                echo "proton-setup: Drive login failed, check the code and try again" >&2
                exit 1
              fi
              rclone config update protondrive 2fa "" >/dev/null
              echo "proton-setup: Drive connected" >&2
              ;;

            calendar)
              # proton-cli reads these three from the environment and persists
              # the session under ~/.config/proton-cli once they work. Exported
              # for the child only; this shell exits moments later.
              export PROTON_USER="$email"
              export PROTON_PASSWORD="$password"
              export PROTON_TOTP="$totp"
              if ! timeout 120 proton-cli calendar calendars list >/dev/null; then
                echo "proton-setup: calendar login failed, check the code and try again" >&2
                exit 1
              fi
              echo "proton-setup: calendar connected" >&2
              ;;

            *)
              echo "proton-setup: connect needs a target: drive or calendar" >&2
              exit 2
              ;;
          esac
          ;;

        *)
          echo "usage: proton-setup status | proton-setup connect {drive|calendar}" >&2
          echo "       connect reads email, password and TOTP as three lines on stdin" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  home.packages = [ setup ];
}
