# Local SearXNG metasearch instance on 127.0.0.1:8888 — the default search
# backend for every browser except Tor Browser (Brave policy in desktop.nix,
# LibreWolf + Epiphany in nix/home) and for Claude Code through the searxng
# MCP bridge (nix/home/ai/claude.nix). The consumers repeat the URL literally:
# the Home Manager side would need osConfig coupling to read it from here,
# and the port below is the only place it is ever defined system-side.
#
# `dots-sandbox triage --assist`'s privacy-gated `searxng_search` tool
# (nix/home/sandbox/triage.nix passes this same address through as
# DOTS_TRIAGE_SEARXNG_ENDPOINT) is one more such repeating consumer, added
# unconditionally — it needs no gating here since this service already runs
# regardless of the triage assist flag. The systemd UNIT this module
# produces is named `searx` (`services.searx.*` above), never `searxng`;
# `systemctl is-active searxng` reports inactive/not-found on this exact
# module, so nothing wiring against it should ever spell the unit name with
# the trailing `ng`. `search.formats` already lists "json" below, which is
# what lets a plain HTTP client (no browser) get structured results back.
{ pkgs, ... }:
{
  services.searx = {
    enable = true;
    # searxng refuses to start on the packaged placeholder secret_key; the
    # module's searx-init oneshot runs envsubst over settings.yml with this
    # file as EnvironmentFile, so the real key stays out of the Nix store.
    environmentFile = "/var/lib/searx/env";
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = 8888;
        secret_key = "$SEARX_SECRET_KEY";
        # single-user localhost instance — the bot-protection limiter (and
        # its Valkey dependency) would only get in the way
        limiter = false;
        public_instance = false;
      };
      search = {
        # json feeds the Claude Code MCP bridge; html is the browser UI
        formats = [
          "html"
          "json"
        ];
        # backend for /autocompleter — the browsers' omnibox suggestions
        autocomplete = "duckduckgo";
      };
      # the simple theme's dark palette (instance-wide default)
      ui.theme_args.simple_style = "dark";
    };
  };

  # First-boot secret generation: root-owned, mode 0600 via umask, and only
  # ever read by systemd itself when it assembles searx-init's environment.
  systemd.services.searx-keygen = {
    description = "Generate the SearXNG secret key";
    before = [ "searx-init.service" ];
    requiredBy = [ "searx-init.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "searx";

      # This unit is `openssl rand -hex 32` piped into a file under its own
      # StateDirectory and nothing else, so it can take the full mechanical
      # hardening set with no functional risk:
      #   NoNewPrivileges       - blocks gaining privilege via a setuid/
      #                           setgid exec; openssl needs none.
      #   ProtectSystem=strict  - makes the whole filesystem read-only
      #                           except StateDirectory=searx, which
      #                           systemd already mounts read-write under
      #                           strict mode — the one path this script
      #                           writes.
      #   ProtectHome           - no path under /home is ever touched.
      #   PrivateTmp            - no /tmp use at all.
      #   PrivateDevices        - no device node is opened.
      #   ProtectKernelTunables - no sysctl/procfs tunable is read or set.
      #   ProtectKernelModules  - never loads/queries a kernel module.
      #   ProtectControlGroups  - never touches the cgroupfs.
      #   RestrictNamespaces    - never creates or enters a namespace.
      #   LockPersonality       - never switches ABI personality.
      #   MemoryDenyWriteExecute - openssl's keygen path allocates no
      #                           executable pages; safe to deny W^X.
      #   RestrictRealtime      - no realtime scheduling is requested.
      #   RestrictSUIDSGID      - the file it writes is a plain env file,
      #                           never setuid/setgid.
      #   RestrictAddressFamilies = [] - no socket of any family is opened;
      #                           this is entirely offline.
      #   CapabilityBoundingSet = [] - runs implicitly as root (module sets
      #                           no User=) but needs no Linux capability
      #                           at all to write into its own state dir.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ ];
      CapabilityBoundingSet = [ ];
    };
    script = ''
      if [ ! -s /var/lib/searx/env ]; then
        (
          umask 077
          printf 'SEARX_SECRET_KEY=%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 32)" > /var/lib/searx/env
        )
      fi
    '';
  };
}
