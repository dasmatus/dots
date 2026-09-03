# Proton Calendar in Thunderbird, read-only, via a generated .ics file.
#
# Read-only is the ceiling, not a shortcut. Proton Calendar has no CalDAV
# endpoint — Proton says so themselves on
# <https://proton.me/support/subscribe-to-external-calendar>: "Proton Calendar
# doesn't support CalDAV, so you can't set up a direct two-way sync with an
# external calendar." Events are end-to-end encrypted and only the clients
# holding the account keys can decrypt them, so no DAV client — Thunderbird,
# Evolution, DAVx5 — can ever talk to it directly. Anything claiming two-way
# Proton Calendar sync is either lying or is a client that reimplemented the
# Proton API, which is exactly what proton-cli is.
#
# So the chain is: proton-cli decrypts events with the account keys, this
# module renders them to a local .ics on a timer, and Thunderbird subscribes
# to that file. Edits still happen in Proton's own web/mobile app; Thunderbird
# is a viewer. That is a real limitation, not a bug in this module.
#
# Why the rendering step exists at all: nixpkgs ships proton-cli 1.10.0, whose
# `calendar events` verbs are create/delete/get/list/respond/update with
# --output text|json|yaml. The upstream README advertises ".ics in and out",
# but no ICS flag exists on any subcommand in 1.10.0 — that surface landed
# after the packaged release. JSON is therefore the export format, and the
# field names below are taken from upstream's Event struct tags
# (internal/service/calendar/events.go), not guessed.
{
  config,
  lib,
  pkgs,
  ...
}:
let

  icsDir = "${config.xdg.stateHome}/proton-calendar";
  icsFile = "${icsDir}/proton.ics";

  # A fixed UUID, not a generated one: Thunderbird keys its calendar registry
  # by this string, so regenerating it on every rebuild would orphan the old
  # calendar and silently add a duplicate beside it every switch.
  calendarId = "9f3c1a6e-2b74-4d58-8e21-5c0a7d4b6f83";

  # ICS text escaping per RFC 5545 §3.3.11, as a program file rather than an
  # inline shell string: the escapes here are load-bearing and would otherwise
  # have to survive Nix, then the shell, then jq's own string parser.
  #
  # Backslash is replaced first so the escapes the later rules add are not
  # themselves re-escaped. Tabs are flattened to spaces because the records
  # are tab-separated below.
  #
  # join with 0x1f rather than @tsv: @tsv applies its OWN backslash/tab/newline
  # escaping, which double-escapes everything `esc` just produced — a literal
  # backslash in a location came out as four. Verified against a fixture:
  # "Raum \ 3B" renders as "Raum \\ 3B" and "Mathe; Klausur, Teil 2" as
  # "Mathe\; Klausur\, Teil 2", both exactly one level of escaping.
  eventsJq = pkgs.writeText "proton-calendar-events.jq" ''
    def esc: (. // "") | tostring
      | gsub("\\\\"; "\\\\")
      | gsub(";"; "\\;")
      | gsub(","; "\\,")
      | gsub("\r"; "")
      | gsub("\n"; "\\n")
      | gsub("\t"; " ");
    .[] | [
      (.uid // .id), .start, .end, (.all_day | tostring),
      (.title | esc), (.location | esc), (.description | esc),
      (.rrule // ""), (.status // "CONFIRMED")
    ] | join("\u001f")
  '';

  exporter = pkgs.writeShellApplication {
    name = "proton-calendar-export";
    runtimeInputs = [
      pkgs.proton-cli
      pkgs.jq
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      out=${lib.escapeShellArg icsFile}
      mkdir -p ${lib.escapeShellArg icsDir}
      tmp=$(mktemp "${icsDir}/.proton.ics.XXXXXX")
      trap 'rm -f "$tmp"' EXIT

      # A rolling window rather than the whole history: Proton returns every
      # occurrence of a recurring event inside the range, so an unbounded
      # range on a long-lived account is both slow and enormous. A year ahead
      # covers scheduling; 90 days back covers "what did I do last term".
      window_start=$(date -u -d '90 days ago' +%Y-%m-%d)
      window_end=$(date -u -d '365 days' +%Y-%m-%d)
      stamp=$(date -u +%Y%m%dT%H%M%SZ)

      emit_events() {
        local cal_id="$1"
        proton-cli calendar events list \
          --calendar "$cal_id" \
          --start "$window_start" --end "$window_end" \
          --output json \
          | jq -r -f ${eventsJq}
      }

      render() {
        local uid start end allday title location description rrule status
        # IFS is the ASCII Unit Separator, NOT a tab. Tab is an IFS-whitespace
        # character, so `IFS=$'\t' read` collapses runs of tabs and silently
        # drops empty fields — an event with no location shifted every later
        # field left by one, putting the status into LOCATION and leaving
        # STATUS empty. 0x1f is not whitespace, so empty fields survive, and
        # it cannot occur in calendar text.
        while IFS=$'\x1f' read -r uid start end allday title location description rrule status; do
          [ -n "$uid" ] || continue
          printf 'BEGIN:VEVENT\n'
          printf 'UID:%s\n' "$uid"
          printf 'DTSTAMP:%s\n' "$stamp"
          if [ "$allday" = "true" ]; then
            # All-day events take the calendar date verbatim — no timezone
            # conversion. Proton returns midnight in the event's own zone, so
            # `date -u` would turn 2026-10-26T00:00+01:00 into 2026-10-25Z and
            # move every all-day event a day earlier for any positive offset.
            printf 'DTSTART;VALUE=DATE:%s\n' "$(echo "''${start:0:10}" | tr -d -)"
            printf 'DTEND;VALUE=DATE:%s\n' "$(echo "''${end:0:10}" | tr -d -)"
          else
            # Timed events do fold to UTC, so the file carries no VTIMEZONE
            # and still lands at the right wall-clock time in Thunderbird.
            printf 'DTSTART:%s\n' "$(date -u -d "$start" +%Y%m%dT%H%M%SZ)"
            printf 'DTEND:%s\n' "$(date -u -d "$end" +%Y%m%dT%H%M%SZ)"
          fi
          printf 'SUMMARY:%s\n' "$title"
          if [ -n "$location" ]; then printf 'LOCATION:%s\n' "$location"; fi
          if [ -n "$description" ]; then printf 'DESCRIPTION:%s\n' "$description"; fi
          if [ -n "$rrule" ]; then printf 'RRULE:%s\n' "$rrule"; fi
          printf 'STATUS:%s\n' "$(echo "$status" | tr '[:lower:]' '[:upper:]')"
          printf 'END:VEVENT\n'
        done
      }

      {
        printf 'BEGIN:VCALENDAR\n'
        printf 'VERSION:2.0\n'
        printf 'PRODID:-//dots//proton-cli %s//EN\n' "$(proton-cli --version | awk '{print $NF}')"
        printf 'CALSCALE:GREGORIAN\n'
        printf 'X-WR-CALNAME:Proton\n'

        # Every calendar on the account is folded into one file so the
        # Thunderbird registry below can stay static — the set of calendars is
        # discovered at runtime and would otherwise need a prefs rewrite (and
        # a Thunderbird restart) each time one is added.
        proton-cli calendar calendars list --output json \
          | jq -r '.[].id' \
          | while read -r cal_id; do emit_events "$cal_id" | render; done

        printf 'END:VCALENDAR\n'
      } > "$tmp"

      # RFC 5545 §3.1 content lines are folded at 75 octets, continuation
      # lines starting with a single space. Thunderbird tolerates long lines,
      # but other consumers of this file (a phone, another client) may not.
      # CRLF is applied in the same pass since the spec requires it.
      awk '{
        line = $0
        while (length(line) > 73) {
          printf "%s\r\n ", substr(line, 1, 73)
          line = substr(line, 74)
        }
        printf "%s\r\n", line
      }' "$tmp" > "$tmp.folded"

      # An empty VCALENDAR means the export failed (expired session, network
      # down). Publishing it would blank the calendar in Thunderbird, so keep
      # the last good file and fail the unit instead.
      if ! grep -q 'BEGIN:VEVENT' "$tmp.folded" && [ -s "$out" ]; then
        echo "proton-calendar: export produced no events, keeping previous $out" >&2
        rm -f "$tmp.folded"
        exit 1
      fi

      # Atomic publish: Thunderbird polls this path and must never observe a
      # half-written file.
      mv "$tmp.folded" "$out"
      echo "proton-calendar: wrote $(grep -c 'BEGIN:VEVENT' "$out") events to $out" >&2
    '';
  };
in
{
  home.packages = [ pkgs.proton-cli ];

  systemd.user.services.proton-calendar-export = {
    Unit = {
      Description = "Export Proton Calendar to a local .ics for Thunderbird";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe exporter;
      # No credentials are configured here at all, and none are needed.
      #
      # proton-cli authenticates by SRP and then persists the session under
      # ~/.config/proton-cli, so the account password is required exactly once
      # per machine. Log in interactively before enabling the timer:
      #
      #   proton-cli calendar calendars list
      #
      # which prompts for the password and a TOTP code, then never again.
      # /home is a plain btrfs subvolume here, not routed through impermanence
      # (nix/modules/impermanence.nix persists a curated list and /home is not
      # on it because it never gets wiped), so that session survives the tmpfs
      # root wipe and every later run is unattended.
      #
      # Deliberately NOT sourced from protonmail-bridge, which cannot supply
      # them. Bridge's `info` prints the password IT generated for its own
      # localhost IMAP/SMTP listener — a random string Bridge invented, not
      # the Proton account password, and useless against the Proton API, which
      # requires an SRP proof derived from the real one. Bridge's own session
      # is sealed in ~/.config/protonmail/bridge-v3/vault.enc, encrypted with a
      # key held in the Secret Service keyring, and the Bridge CLI has no
      # export command (its only subcommand is `help`). So there is nothing to
      # hand over, in either direction.
      #
      # A security key is likewise no help to a timer: neither proton-cli nor
      # rclone speaks FIDO2, and a hardware key cannot be tapped unattended.
      # TOTP is what makes the one-time interactive login above possible.
      #
      # A failed run is almost always an expired session, and retrying it on a
      # tight loop just burns API calls, so back off well past the 15-minute
      # timer and let the next scheduled run pick things up.
      Restart = "on-failure";
      RestartSec = "30m";
    };
  };

  systemd.user.timers.proton-calendar-export = {
    Unit.Description = "Schedule the Proton Calendar export";
    Timer = {
      OnBootSec = "2m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "1m";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Thunderbird's calendar list lives in prefs, keyed by the fixed UUID above.
  # `type = "ics"` with a file:// URI is the plain-file provider; cache.enabled
  # stays false so Thunderbird re-reads the file the exporter rewrites instead
  # of serving its own stale copy of it.
  programs.thunderbird.profiles.default.settings = {
    "calendar.registry.${calendarId}.type" = "ics";
    "calendar.registry.${calendarId}.uri" = "file://${icsFile}";
    "calendar.registry.${calendarId}.name" = "Proton";
    "calendar.registry.${calendarId}.color" = "#6d4aff";
    "calendar.registry.${calendarId}.calendar-main-in-composite" = true;
    "calendar.registry.${calendarId}.calendar-main-default" = true;
    "calendar.registry.${calendarId}.cache.enabled" = false;
    "calendar.registry.${calendarId}.disabled" = false;
    # Read-only is enforced here as well as being inherent: without it
    # Thunderbird offers an edit dialog whose saves are silently lost on the
    # next export, which reads as data loss to anyone who tries it.
    "calendar.registry.${calendarId}.readOnly" = true;
    "calendar.registry.${calendarId}.refreshInterval" = 15;
    "calendar.list.sortOrder" = calendarId;
  };
}
