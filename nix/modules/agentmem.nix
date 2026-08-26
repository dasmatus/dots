# Local PostgreSQL cluster backing the dots-memory Claude Code plugin — see
# docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md. This
# module owns the cluster only: no schema, no extension, no plugin wiring —
# those land in later plans on top of the same `agentmem` role/database.
#
# Gated on the same flag as the plugin it serves (nix/home/claude.nix:122):
# the cluster has no reason to exist when Claude Code's Home Manager config
# is off. Package is pinned to postgresql_18 explicitly (never mkDefault) —
# maintenance.nix autoupgrades the channel daily, and an unpinned package
# would move psqlSchema/dataDir under a live cluster the moment nixpkgs
# gains postgresql_19. enableTCPIP stays false: peer auth over the unix
# socket is the only auth story here (no secrets manager in this repo, and
# firewalld's DefaultZone = "drop" makes TCP pointless besides).
{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = lib.mkIf config.dots.ai.claude {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_18;
      ensureDatabases = [ config.dots.username ];
      ensureUsers = [
        {
          name = config.dots.username;
          ensureDBOwnership = true;
        }
      ];
      enableTCPIP = false;
    };

    # location moves the dump off /var/backup/postgresql (the module
    # default, which lives on the tmpfs root) onto the persisted cluster
    # parent — a subdir of it, so no second impermanence entry is needed.
    services.postgresqlBackup = {
      enable = true;
      location = "/var/lib/postgresql/backup";
      startAt = "daily";
    };
  };
}
