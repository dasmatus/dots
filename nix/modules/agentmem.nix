## agentmem — the Postgres-backed memory plugin's cluster, schema and
## privilege boundary (docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md).
##
## This module is assembled from three plans that each own one slice:
##   plan 0 (cluster)   -- services.postgresql/postgresqlBackup, peer auth,
##                          persistence. Not present in this worktree; the
##                          settings below are this plan's best-effort
##                          reconstruction of what plan 0 is expected to
##                          contribute, so migration 2's pieces have
##                          something to attach to. Reconcile against
##                          plan 0's actual file before this ships.
##   plan 1 (extension) -- pgAgentmem, the pgrx package this module loads
##                          via services.postgresql.extensions. Passed in
##                          as a module argument (flake/nixos.nix specialArgs,
##                          same pattern as wallpaperTui/hyprmon below it),
##                          not yet wired because plan 1 has not run here.
##   plan 2 (this plan) -- the migration runner, the ident map entry for
##                          agentmem_mcp, and nix/modules/agentmem/migrations/.
##
## Peer auth maps OS user matus to both roles over the unix socket
## (nix/hosts.nix:55-90 rules out DynamicUser and ReadWritePaths here —
## see the design spec section 9). No password exists anywhere.
{
  config,
  lib,
  pkgs,
  pgAgentmem ? null,
  ...
}:
let
  cfg = config.dots.ai.claude;
  migrationsDir = ./agentmem/migrations;
in
{
  services.postgresql = {
    enable = lib.mkIf cfg true;
    package = pkgs.postgresql_18;
    enableTCPIP = false;
    extensions = lib.mkIf cfg (
      ps: lib.optional (pgAgentmem != null) pgAgentmem ++ [ ps.pg_trgm ps.unaccent ]
    );
    ensureDatabases = lib.mkIf cfg [ "matus" ];
    ensureUsers = lib.mkIf cfg [
      {
        name = "matus";
        ensureDBOwnership = true;
      }
      {
        name = "agentmem_mcp";
      }
    ];
    identMap = lib.mkIf cfg ''
      agentmem-map matus matus
      agentmem-map matus agentmem_mcp
    '';
    authentication = lib.mkIf cfg ''
      local matus matus         peer map=agentmem-map
      local matus agentmem_mcp  peer map=agentmem-map
    '';

    # Idempotent migration runner: agentmem._migrations tracks which of
    # nix/modules/agentmem/migrations/*.sql already applied, by filename,
    # so a rebuild that adds a migration only ever runs the new one.
    # Deliberately not `initialScript` -- that option is `types.path` and
    # lands world-readable in the store (design spec section 9); running
    # from postStart under the postgres service's own permissions avoids
    # that without needing a secrets manager this repo does not have.
    postStart = lib.mkIf cfg ''
      PSQL="${config.services.postgresql.package}/bin/psql -U matus -d matus -v ON_ERROR_STOP=1"

      $PSQL -c "
        CREATE SCHEMA IF NOT EXISTS agentmem;
        CREATE TABLE IF NOT EXISTS agentmem._migrations (
          filename   text PRIMARY KEY,
          applied_at timestamptz NOT NULL DEFAULT now()
        );
      "

      for f in ${migrationsDir}/*.sql; do
        name=$(basename "$f")
        applied=$($PSQL -tAc "SELECT 1 FROM agentmem._migrations WHERE filename = '$name'")
        if [ "$applied" != "1" ]; then
          $PSQL -f "$f"
          $PSQL -c "INSERT INTO agentmem._migrations (filename) VALUES ('$name')"
        fi
      done
    '';
  };

  services.postgresqlBackup = {
    enable = lib.mkIf cfg true;
    # A subdir of the persisted /var/lib/postgresql, not the impermanence
    # default (/var/backup/postgresql, itself on the wiped tmpfs root) --
    # no second impermanence entry needed.
    location = "/var/lib/postgresql/backup";
    startAt = "daily";
  };
}
