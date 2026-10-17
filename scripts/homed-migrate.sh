#!/usr/bin/env bash
# Prepare an existing (userborn) install for the switch to a systemd-homed
# login account (nix/modules/system/homed.nix).
#
# Run it once, as root (`run0 scripts/homed-migrate.sh <user>`), on the
# system as it is now, before rebuilding into the homed configuration. It
# asks for the account's password and writes the credential
# systemd-homed-firstboot creates the account from:
#
#   /persist/etc/credstore/home.create.<user>
#
# The record keeps the user's current uid and supplementary groups, so files
# under /home/<user> need no chown. Nothing else is touched here: on the next
# boot of the new generation dots-homed-migrate moves /home/<user> to
# /home/<user>.pre-homed, homed creates the account, and
# dots-homed-migrate-data copies the old files into the new home area
# (reflinked on btrfs). The old directory stays until you delete it.
#
# Then:
#   nixos-rebuild boot --flake .#tokyonight
#   reboot
#
# If the account does not appear after that boot, homectl's wizard asks for
# one on the console. To go back instead, pick the previous generation in the
# Limine menu, log in, and `run0 mv /home/<user>.pre-homed /home/<user>`.
set -euo pipefail

user=${1:?usage: homed-migrate.sh <user>}
for tool in jq mkpasswd; do
  command -v "$tool" >/dev/null || {
    echo "$tool is missing; run inside: nix shell nixpkgs#jq nixpkgs#mkpasswd" >&2
    exit 1
  }
done
credstore=/persist/etc/credstore
credential=$credstore/home.create.$user

[[ $EUID -eq 0 ]] || {
  echo "run as root: run0 $0 $user" >&2
  exit 1
}
uid=$(id -u "$user")
primary=$(id -gn "$user")
mapfile -t groups < <(id -nG "$user" | tr ' ' '\n' | grep -vxF "$primary")

[[ -d /persist ]] || {
  echo "/persist is missing; is this the impermanence layout?" >&2
  exit 1
}
[[ ! -e $credential ]] || {
  echo "$credential already exists; remove it to start over" >&2
  exit 1
}

read -rsp "New password for $user (homed): " password
echo
read -rsp "Again: " again
echo
[[ -n $password && $password == "$again" ]] || {
  echo "passwords empty or different" >&2
  exit 1
}

# stdin, not argv: argv is readable by every user through /proc.
hash=$(printf '%s' "$password" | mkpasswd -m yescrypt --stdin)
# shellcheck disable=SC2016 # a literal "$y$" prefix, not an expansion
[[ $hash == '$y$'* ]] || {
  echo "mkpasswd did not produce a yescrypt hash" >&2
  exit 1
}

install -d -m 0700 "$credstore"
umask 077
# The password goes through the environment for the same reason; jq reads it
# with env.
PASSWORD=$password HASH=$hash jq -n \
  --arg user "$user" \
  --argjson uid "$uid" \
  --args '{
    userName: $user,
    realName: $user,
    uid: $uid,
    storage: "subvolume",
    shell: "/run/current-system/sw/bin/fish",
    memberOf: $ARGS.positional,
    enforcePasswordPolicy: false,
    privileged: { hashedPassword: [env.HASH] },
    secret: { password: [env.PASSWORD] }
  }' "${groups[@]}" >"$credential"

echo "Wrote $credential (uid $uid, groups: ${groups[*]:-none})."
echo "Next: nixos-rebuild boot --flake .#tokyonight && reboot"
