# Local SearXNG metasearch instance on 127.0.0.1:8888 — the default search
# backend for every browser except Tor Browser (Brave policy in desktop.nix,
# LibreWolf + Epiphany in nix/home) and for Claude Code through the searxng
# MCP bridge (nix/home/ai/claude.nix). The consumers repeat the URL literally:
# the Home Manager side would need osConfig coupling to read it from here,
# and the port below is the only place it is ever defined system-side.
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
