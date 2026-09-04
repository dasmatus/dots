# dots-memory Plan 0: Postgres Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** A pinned PostgreSQL 18.4 cluster runs on this host, reachable
over the unix socket by peer auth, surviving a reboot, with backups.
**Architecture:** One module owns the cluster only: no schema, no
extension, no plugin. Gated on the flag the plugin will later gate on.
**Tech Stack:** NixOS, `pkgs.postgresql_18`, nixos-impermanence.
**Spec:** `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`

## Global Constraints
- Gate: `lib.mkIf config.dots.ai.claude` (`nix/home/ai/claude.nix:122`).
- `package = pkgs.postgresql_18;` (18.4), never `mkDefault`, since
  `maintenance.nix` autoupgrades the channel daily.
- `enableTCPIP` stays false. Peer auth only. No password anywhere.
- Never `DynamicUser` (`hosts.nix:55-72`, EBUSY on a bind mount) or
  `ReadWritePaths` on a directory needing creation (`hosts.nix:74-90`,
  226/NAMESPACE). The postgresql module uses neither by default.
- Persist `/var/lib/postgresql`, the parent, not the `psqlSchema` subdir.
  Owner `postgres:postgres`, mode `0750` (its `StateDirectoryMode`).
- Open risk, unmitigated: no `pg_upgrade` rehearsal exists for this
  cluster; `services.postgresql.upgrade` has no such option.

---
### Task 1: Write the cluster module
**Files:** create `nix/modules/services/agentmem.nix`.
**Produces:** `services.postgresql` (enable; package `pkgs.postgresql_18`;
`ensureDatabases = [ settings.username ]`; `ensureUsers = [ { name =
settings.username; ensureDBOwnership = true; } ]`; `enableTCPIP = false`)
and `services.postgresqlBackup` (enable; `location =
"/var/lib/postgresql/backup"`, a subdir of the persisted parent, no
second impermanence entry needed; `startAt = "daily"`), one `lib.mkIf`.

- [ ] **1** Write `nix/modules/services/agentmem.nix` per Produces above,
      imitating `nix/modules/services/searxng.nix`'s comment style
- [ ] **2** `git add nix/modules/services/agentmem.nix && nix-instantiate --parse
      nix/modules/services/agentmem.nix` Expected: staged, exit 0
- [ ] **3** `git commit -m "feat: add the agentmem postgres cluster module"`

### Task 2: Wire the module in and persist its data
**Files:** modify `flake/nixos.nix:43`, `nix/modules/system/impermanence.nix:51`.
**Produces:** `config.services.postgresql` reachable through
`nixosConfigurations.tokyonight`; a persisted `/var/lib/postgresql`.

- [ ] **1** In `flake/nixos.nix`, add `../nix/modules/services/agentmem.nix` as
      new line 44, directly after `../nix/modules/services/searxng.nix`
- [ ] **2** In `impermanence.nix`, after `/var/lib/ollama` (line 51),
      add `{ directory = "/var/lib/postgresql"; user = "postgres";
      group = "postgres"; mode = "0750"; }`
- [ ] **3** `git add flake/nixos.nix nix/modules/system/impermanence.nix`
      Expected: both staged before the eval below
- [ ] **4** `T=.#nixosConfigurations.tokyonight.config.services.postgresql`
      then `nix eval $T.package.version && nix eval $T.enableTCPIP`
      Expected: `"18.4"` then `false`
- [ ] **5** `nix run .#nix-lint` Expected: green
- [ ] **6** `git commit -m "feat: wire agentmem into the flake and persist it"`

### Task 3: VM test for socket reachability and reboot survival
**Files:** modify `tests/default.nix` (new `agentmem-postgres` check),
`tests/README.md` (new table row).
**Produces:** `checks.x86_64-linux.agentmem-postgres`.

- [ ] **1** Add a `runNixOSTest` node importing
      `../nix/modules/system/impermanence.nix`, with `services.postgresql` and
      `services.postgresqlBackup` set as in `agentmem.nix` (role/db
      `"test"`) plus `users.users.test.isNormalUser = true;`
- [ ] **2** Script: `wait_for_unit("postgresql.service")`, then
      `succeed("sudo -u test psql -h /run/postgresql -d test -c "
      "'select 1;'")` Expected: proves the socket and peer auth
- [ ] **3** Create a table, `shutdown()`, `start()`, re-query it, then
      `systemctl start` the backup unit and check a dump file under
      `/var/lib/postgresql/backup` Expected: table and backup both there
- [ ] **4** Add the `agentmem-postgres` row to `tests/README.md`
- [ ] **5** `nix run .#nix-smoke -- .#checks.x86_64-linux.agentmem-postgres`
      Expected: build succeeds, test script passes
- [ ] **6** `git add tests/default.nix tests/README.md &&
      git commit -m "test: add a vm check for the agentmem cluster"`
