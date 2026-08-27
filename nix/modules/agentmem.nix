# Local PostgreSQL cluster backing the dots-memory Claude Code plugin — see
# docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md.
#
# Assembled from three plans that each own one slice:
#   plan 0 (cluster)   -- services.postgresql/postgresqlBackup, peer auth,
#                          persistence, the pinned package.
#   plan 1 (extension) -- pgAgentmem, the pgrx package loaded via
#                          services.postgresql.extensions. Passed in as a
#                          module argument (flake/nixos.nix specialArgs,
#                          same pattern as wallpaperTui/hyprmon below it).
#   plan 2 (schema)    -- the migration runner, the ident map entry for
#                          agentmem_mcp, and nix/modules/agentmem/migrations/.
#
# Gated on the same flag as the plugin it serves (nix/home/claude.nix): the
# cluster has no reason to exist when Claude Code's Home Manager config is
# off. Package is pinned to postgresql_18 explicitly (never mkDefault) --
# maintenance.nix autoupgrades the channel daily, and an unpinned package
# would move psqlSchema/dataDir under a live cluster the moment nixpkgs
# gains postgresql_19. enableTCPIP stays false: peer auth over the unix
# socket is the only auth story here (no secrets manager in this repo, and
# firewalld's DefaultZone = "drop" makes TCP pointless besides).
{
  config,
  pkgs,
  lib,
  pgAgentmem ? null,
  ...
}:
let
  username = config.dots.username;
  migrationsDir = ./agentmem/migrations;
in
{
  config = lib.mkIf config.dots.ai.claude {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_18;
      enableTCPIP = false;
      # Only pg_agentmem. pg_trgm and unaccent are contrib and already ship
      # inside the base package's share/postgresql/extension, so there is no
      # postgresql18Packages attribute to name here and listing them fails
      # eval with "attribute 'pg_trgm' missing". Migration 0001 reaches them
      # with a plain CREATE EXTENSION, which is all they ever needed.
      extensions = _ps: lib.optional (pgAgentmem != null) pgAgentmem;
      ensureDatabases = [ username ];
      ensureUsers = [
        {
          name = username;
          ensureDBOwnership = true;
        }
        {
          name = "agentmem_mcp";
        }
      ];

      # Peer auth maps OS user `username` to both roles over the unix
      # socket (nix/hosts.nix rules out DynamicUser and ReadWritePaths here
      # -- see the design spec section 9). No password exists anywhere.
      identMap = ''
        agentmem-map ${username} ${username}
        agentmem-map ${username} agentmem_mcp
      '';
      authentication = ''
        local ${username} ${username}         peer map=agentmem-map
        local ${username} agentmem_mcp        peer map=agentmem-map
      '';

    };

    # Idempotent migration runner: agentmem._migrations tracks which of
    # nix/modules/agentmem/migrations/*.sql already applied, by filename, so a
    # rebuild that adds a migration only ever runs the new one.
    #
    # Deliberately not `initialScript` -- that option is `types.path` and lands
    # world-readable in the store (design spec section 9), and it runs only on
    # the very first cluster start, so a migration added later would never
    # apply.
    #
    # Its own unit rather than a postStart on either postgresql.service or
    # postgresql-setup.service. `services.postgresql.postStart` is not an
    # option at all. postgresql.service is too early: ensureDatabases and
    # ensureUsers run in postgresql-setup.service, so the database and the
    # roles do not exist yet. And postgresql-setup runs as `postgres`, whose
    # peer identity cannot authenticate as ${username}, while every function
    # below is SECURITY DEFINER -- owned by postgres they would carry
    # superuser rights instead of the database owner's, which is the opposite
    # of what the privilege boundary is for.
    systemd.services.agentmem-migrate = {
      description = "Apply agentmem schema migrations";
      requires = [ "postgresql-setup.service" ];
      after = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
        Group = "users";
      };
      script = ''
        PSQL="${config.services.postgresql.package}/bin/psql -U ${username} -d ${username} -v ON_ERROR_STOP=1"

        # Repair path for a cluster bootstrapped by the earlier runner, which
        # created the schema itself. That leaves a schema no extension owns,
        # and CREATE EXTENSION then fails forever with "schema agentmem is not
        # a member of extension pg_agentmem": an extension script's
        # IF NOT EXISTS may only skip an object the extension already owns.
        # Guarded so it can only ever drop the empty leftover: the extension
        # must be absent and no migration recorded, which together mean
        # nothing has been stored yet.
        $PSQL -c "
          DO \$\$
          DECLARE applied bigint := 0;
          BEGIN
            IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_agentmem')
               OR to_regnamespace('agentmem') IS NULL THEN
              RETURN;
            END IF;
            IF to_regclass('agentmem._migrations') IS NOT NULL THEN
              EXECUTE 'SELECT count(*) FROM agentmem._migrations' INTO applied;
            END IF;
            IF applied = 0 THEN
              RAISE NOTICE 'dropping the unowned agentmem schema left by the earlier bootstrap';
              DROP SCHEMA agentmem CASCADE;
            END IF;
          END \$\$;
        "

        # The extension creates and owns the schema, so it has to come first:
        # pgrx's #[pg_schema] emits its own CREATE SCHEMA IF NOT EXISTS, and
        # 0001_schema.sql deliberately does not, for the reason above.
        # _migrations then lands inside a schema the extension already owns.
        $PSQL -c "
          CREATE EXTENSION IF NOT EXISTS pg_agentmem;
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
