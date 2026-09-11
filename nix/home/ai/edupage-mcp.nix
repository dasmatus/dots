# edupage-mcp: MCP server for Edupage, the school information system used
# across central Europe (github.com/mhlavac/edupage-mcp): timetables,
# grades, homework, messages. Upstream publishes no PyPI release and no
# tag, and its own setup instructions are `uv run --directory
# /path/to/clone`, which would make it the one MCP server in this config
# that clones imperatively and resolves dependencies over the network at
# spawn. Both halves are therefore built from source here: edupage-api off
# PyPI (absent from nixpkgs), and the server off a pinned GitHub rev. The
# MCP SDK itself is nixpkgs' python3Packages.mcp, the same one
# nix/home/ai/claude.nix builds its searxng bridge against.
#
# Both packages are GPL-3.0-or-later. The server is its own process
# speaking JSON-RPC over stdio, so the copyleft stops at that process
# boundary and does not reach this configuration; it would start to matter
# only if any of its code were vendored in.
#
# Credentials never enter the Nix store. Home Manager's
# `mcpServers.<name>.env` would write the school password into a
# world-readable store path and commit it to a public repo, so the command
# registered below is a wrapper that reads the values out of the login
# keyring (gnome-keyring, enabled in nix/modules/desktop/desktop.nix) through
# libsecret's secret-tool at spawn time. That is the same Secret Service
# nix/home/shell/git.nix already uses via `credential.helper = "libsecret"`.
# Username and subdomain live in the keyring next to the password rather
# than as literals below: both identify the human behind a public repo.
#
# Home Manager does ship a secret mechanism for MCP env vars: `env.X.file
# = "/run/secrets/x"`, which modules/lib/mcp.nix turns into a generated
# wrapper that reads the file at startup. Two things rule it out here. It
# resolves a plaintext file rather than a keyring, and it is wired to
# `programs.mcp.servers` alone. The claude-code module puts its own
# cfg.mcpServers through addType and nothing else, so a file ref on this
# option is serialised into .mcp.json verbatim as {"file": "..."} rather
# than resolved. That fails silently instead of erroring, which is the
# kind of thing worth knowing before reaching for the attribute.
#
# One-time imperative step this module cannot do for you: run
# `edupage-keyring` once and answer the three prompts. Until then the
# server still starts, just without auto-login, and its `login` tool is
# the way in. Re-run it to change credentials.
#
# Known rough edge: nix/modules/system/core.nix turns on PAM keyring unlock for
# the `login` service only, and this box logs in through regreet/greetd,
# so the collection can still be locked on a fresh boot. That matters more
# than a stray dialog would suggest. secret-tool has no way to decline an
# unlock prompt: `lookup` unlocks unconditionally, and only `search`
# takes `--unlock`, and libsecret resolves the prompt through a plain
# g_main_loop_run with no deadline and no cancellable, so an unanswered
# dialog blocks the caller for as long as it goes unanswered. The wrapper
# below caps every lookup at ten seconds for exactly that reason; without
# the cap an unattended spawn would hang before the exec and leave the MCP
# connection with nothing on its stdio pipe at all.
# `security.pam.services.greetd.enableGnomeKeyring = true` would remove
# the prompt at the source; left alone deliberately, because it changes
# how the graphical session authenticates, which is a bigger decision than
# this module gets to make.
{
  lib,
  pkgs,
  dots,
  ...
}:
let
  py = pkgs.python3Packages;

  # The Edupage HTTP client the MCP server wraps. Not in nixpkgs; plain
  # setuptools sdist whose only runtime dependency is requests. PyPI names
  # the artifact with an underscore while the distribution is hyphenated,
  # hence the separate pname in fetchPypi.
  edupage-api = py.buildPythonPackage rec {
    pname = "edupage-api";
    version = "0.12.3";
    pyproject = true;

    src = pkgs.fetchPypi {
      pname = "edupage_api";
      inherit version;
      hash = "sha256-OK8GO18SmRiqaeYRU/LIFi144xRNaLtQbIVWH296AUw=";
    };

    build-system = [
      py.setuptools
      py.wheel
    ];
    dependencies = [ py.requests ];

    # The sdist ships no tests; every one upstream has would talk to a real
    # school's Edupage instance anyway, which a build cannot do.
    doCheck = false;
    pythonImportsCheck = [ "edupage_api" ];

    meta = {
      description = "Python API wrapper for Edupage";
      homepage = "https://github.com/ivanhrabcak/edupage-api";
      license = lib.licenses.gpl3Plus;
    };
  };

  # The server itself. rev pinned to mhlavac/edupage-mcp main HEAD at
  # adoption time and bumped deliberately, the same way claude.nix pins
  # pstackSrc, since there is no upstream tag to track. pyproject.toml declares
  # `edupage-mcp = "edupage_mcp:main"` under [project.scripts], so
  # buildPythonApplication yields a real bin/edupage-mcp and upstream's
  # `python -m edupage_mcp` invocation is unnecessary.
  edupage-mcp = py.buildPythonApplication {
    pname = "edupage-mcp";
    version = "0.1.0-unstable-2026-02-21";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "mhlavac";
      repo = "edupage-mcp";
      rev = "ccf98103bdae0357c20318148ed227c2325e4237";
      hash = "sha256-SNDkzLrkLsTbtIEttwc24Q6dmIGt8h/nqBEhiwrT7ps=";
    };

    build-system = [ py.hatchling ];
    dependencies = [
      py.mcp
      edupage-api
    ];

    doCheck = false;
    pythonImportsCheck = [ "edupage_mcp" ];

    meta = {
      description = "MCP server exposing Edupage timetables, grades, homework and messages";
      homepage = "https://github.com/mhlavac/edupage-mcp";
      license = lib.licenses.gpl3Plus;
      mainProgram = "edupage-mcp";
    };
  };

  # Keyring shim: the actual `command` Claude Code spawns. Every lookup is
  # bounded and its failure swallowed, because the server has to come up
  # either way, since a dead stdio handshake takes the whole MCP connection down
  # with it, while an empty credential only leaves the `login` tool as the
  # way in. server.py gates its startup auto-login on `if username and
  # password and subdomain`, and Python reads "" as false, so exporting
  # empty values is exactly equivalent to exporting nothing.
  #
  # The timeout is the load-bearing part, not decoration. A *missing* item
  # makes secret-tool exit non-zero immediately, which `|| true` handles;
  # a *locked* collection instead makes it block on a Secret Service unlock
  # prompt, and libsecret's synchronous lookup carries no deadline of its
  # own and no flag to decline the prompt. An unattended spawn, whether from
  # a cold boot, a dialog opening behind another window, or nobody watching,
  # would hang before the exec and wedge the MCP connection with no output
  # at all.
  # Ten seconds is deliberately far too short to type a password into that
  # dialog: bounded startup without auto-login beats an indefinite hang.
  # Unlock the keyring and reconnect the server to pick the credentials up.
  edupage-mcp-keyring = pkgs.writeShellApplication {
    name = "edupage-mcp-keyring";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libsecret
    ];
    text = ''
      lookup() {
        timeout 10 secret-tool lookup service edupage attribute "$1" 2>/dev/null || true
      }

      EDUPAGE_USERNAME="$(lookup username)"
      EDUPAGE_PASSWORD="$(lookup password)"
      EDUPAGE_SUBDOMAIN="$(lookup subdomain)"
      export EDUPAGE_USERNAME EDUPAGE_PASSWORD EDUPAGE_SUBDOMAIN

      if [ -z "$EDUPAGE_PASSWORD" ]; then
        echo "edupage-mcp: no password in the login keyring — starting without auto-login." >&2
        echo "edupage-mcp: run 'edupage-keyring' to store credentials, or call the login tool." >&2
      fi

      exec ${lib.getExe edupage-mcp} "$@"
    '';
  };

  # One-time credential setup, the counterpart to bitwarden.nix's
  # dots-keys. secret-tool store reads each value from a tty with echo
  # off and writes it to the default collection, so nothing lands in shell
  # history, in a file, or in this repo. Safe to re-run: storing the same
  # attribute set overwrites the previous item rather than adding a second.
  edupage-keyring = pkgs.writeShellApplication {
    name = "edupage-keyring";
    runtimeInputs = [ pkgs.libsecret ];
    text = ''
      echo "Edupage credentials -> login keyring. Input is not echoed."
      echo

      echo "1/3  username (the school account you log in with):"
      secret-tool store --label='Edupage username' service edupage attribute username

      echo "2/3  password:"
      secret-tool store --label='Edupage password' service edupage attribute password

      echo "3/3  subdomain (the part before .edupage.org; comma-separate for several schools):"
      secret-tool store --label='Edupage subdomain' service edupage attribute subdomain

      echo
      echo "Stored. Restart Claude Code to pick them up; 'seahorse' shows the items."
    '';
  };
in
{
  # Gated on the same installer "AI" toggle as claude.nix's programs.claude-code:
  # with Claude Code off there is no harness to register into, and the setup
  # helper would only be a dead command on PATH.
  config = lib.mkIf dots.ai.claude {
    home.packages = [ edupage-keyring ];

    # Runs unwrapped (Phase E, ruling R3, retired the per-app sandbox — see
    # git history): a stdio MCP server the user's own Claude Code spawns is a
    # developer tool talking to the school's remote API, not untrusted input
    # needing confinement.
    programs.claude-code.mcpServers.edupage = {
      type = "stdio";
      command = lib.getExe edupage-mcp-keyring;
    };
  };
}
