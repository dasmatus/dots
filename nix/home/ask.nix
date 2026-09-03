# dots-ask — the daemon behind the shell's AI side pane
# (docs/superpowers/specs/2026-09-03-ask-pane-design.md).
#
# It is a user service and not part of the Quickshell tree on purpose.
# nix/home/quickshell/default.nix puts the QML on X-Restart-Triggers, so every
# rebuild restarts the shell, and a turn running inside the shell would die
# with it. Splitting it out costs one unix socket in $XDG_RUNTIME_DIR and buys
# a conversation that survives a `home-manager switch` mid-answer.
#
# WHAT GATES WHAT, because there are two gates and they answer different
# questions. This module decides whether the daemon exists at all: with every
# dots.ai toggle off there is no unit, no package and no socket. The pane
# decides whether the key does anything: nix/home/quickshell/tree.nix writes
# ask/backends.json from the same three toggles, and Ask.qml's toggle() returns
# early on an empty list. The SUPER+A bind itself is unconditional
# (nix/home/session/actions.nix), because nix/home/keybinds.nix is an
# argument-free data file that flake/packages.nix imports with no evaluated
# home-manager config behind it. So the bind is always in the table and always
# in the cheatsheet, and the two gates above are what make it a no-op on a
# machine with no AI toggled on.
#
# READINESS: Type=exec, not Type=notify. See the unit below for the argument.
{
  lib,
  pkgs,
  dots,
  inputs,
  ...
}:
let
  dots-ask = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.dots-ask;

  # One-time credential setup, the counterpart to nix/home/edupage-mcp.nix's
  # edupage-keyring. Section 5 of the spec makes secret-tool the only place a
  # provider key may live: the daemon reads it lazily at spawn and never writes
  # one into the store, an event or a log line. Nothing else in this design
  # carries a per-machine secret, and the spec adds no settings key, so the
  # keyring is also where the OpenAI-compatible base URL goes even though a URL
  # is not itself a secret. Keeping the pair together means one helper writes
  # both halves of that backend and the daemon reads one collection.
  #
  # THESE ATTRIBUTE NAMES ARE THE CONTRACT. src/secrets.rs does not exist yet,
  # so whatever this helper writes is what the backend phase has to look up:
  # `service dots-ask`, attributes `anthropic-key`, `openai-key` and
  # `openai-base-url`. claude-code, codex and ollama need nothing here; the
  # harnesses carry their own auth and ollama is a local port.
  #
  # It deviates from edupage-keyring in one way, deliberately. That helper
  # hands the tty straight to `secret-tool store`, which stores whatever it
  # reads, including an empty string. Here an empty item would be worse than a
  # missing one: the spec lists the anthropic backend "when a key is in the
  # keyring", so an empty item makes the pane offer a backend that cannot
  # answer. Reading the value first and skipping the store when it is blank is
  # what makes pressing Enter through a prompt mean "not this one" rather than
  # "yes, with nothing". The value still reaches secret-tool over a pipe, so it
  # never lands in argv, in a file or in shell history.
  ask-keyring = pkgs.writeShellApplication {
    name = "ask-keyring";
    runtimeInputs = [ pkgs.libsecret ];
    text = ''
      # `|| true` because read exits non-zero at EOF and this script runs
      # under set -e. An unanswered prompt is a skip, not a failure.
      store() {
        local label="$1" attribute="$2" value=""
        read -rs value || true
        echo
        if [ -z "$value" ]; then
          echo "  skipped, leaving any existing item alone."
          return 0
        fi
        printf '%s' "$value" \
          | secret-tool store --label="$label" service dots-ask attribute "$attribute"
        echo "  stored."
      }

      echo "dots-ask provider credentials -> login keyring. Input is not echoed."
      echo "Leave a prompt empty to skip it. Claude Code, Codex and Ollama need"
      echo "nothing here: the harnesses carry their own auth and Ollama is local."
      echo

      echo "1/3  Anthropic API key (for the raw provider backend, not for Claude Code):"
      store "dots-ask Anthropic API key" anthropic-key

      echo "2/3  OpenAI-compatible API key:"
      store "dots-ask OpenAI-compatible API key" openai-key

      echo "3/3  OpenAI-compatible base URL (e.g. https://api.openai.com/v1):"
      store "dots-ask OpenAI-compatible base URL" openai-base-url

      echo
      echo "Restart the daemon to pick these up: systemctl --user restart dots-ask"
      echo "'seahorse' shows the stored items."
    '';
  };
in
{
  # Every AI toggle off means no daemon at all. Not a unit that starts and
  # serves an empty backend list: the pane already refuses to open in that
  # state, so a running daemon would be a process nothing can ever talk to.
  config = lib.mkIf (dots.ai.claude || dots.ai.codex || dots.ai.ollama) {
    # The binary itself, so `dots-ask --version` and a by-hand
    # `dots-ask --socket /tmp/x` are available for debugging. The unit below
    # names the store path directly rather than relying on this.
    home.packages = [
      dots-ask
      ask-keyring
    ];

    # Modelled on systemd.user.services.quickshell in
    # nix/home/quickshell/default.nix, with two deliberate differences.
    #
    # NO ConditionPathExists = [ "%t/hypr" ]. The shell reads Hyprland's socket
    # for its workspace pills and its monitor watcher, so it has nothing to do
    # in a session without one. The daemon reads no compositor state at all; it
    # binds a unix socket and talks to whatever connects. Copying that
    # condition would silently mean no AI pane on any other compositor, for no
    # reason anyone could find from here.
    #
    # NO X-Restart-Triggers either, and that one is automatic rather than
    # omitted: ExecStart below is the store path of the daemon, so the unit
    # text changes exactly when the binary does, and sd-switch restarts it
    # then. The shell needs the trigger only because its own ExecStart is a
    # bare `quickshell` that says nothing about which QML tree it will read.
    #
    # TYPE=EXEC, NOT TYPE=NOTIFY, and this is the readiness decision the spec's
    # module map parks under src/main.rs. The choice turns on who would consume
    # the signal. The only client is the pane, and the pane cannot order itself
    # after this unit: the shell has to come up whether or not the daemon does,
    # which is why AskBus.qml already re-dials on a doubling backoff from 500ms
    # and Ask.qml already says "waiting for the dots-ask daemon" while it is
    # down. Nothing else in the session names dots-ask.service at all. So
    # sd_notify would add a dependency to a vendored Cargo.lock, put a second
    # copy of the readiness contract in main.rs, and pay for it with a failure
    # mode nothing tests: `cargo test` never runs main, so a refactor that
    # stops reaching the notify call turns login into a unit stuck in
    # `activating` for TimeoutStartSec and then killed, which reads worse than
    # the crash it replaced.
    #
    # Type=exec is the half of notify that is free. systemd holds the start job
    # until execve() succeeds, so a broken ExecStart fails `systemctl --user
    # start dots-ask` instead of reporting success and dying, and that is the
    # one class of start failure a Nix change here can actually introduce. What
    # it does not cover is a failure after exec, which for this daemon means a
    # socket another instance already holds or one it cannot narrow to 0600.
    # Both are fatal, both print a miette diagnostic to the journal, and
    # Restart=on-failure puts them in front of the user as a failed unit within
    # seconds rather than hiding them.
    #
    # Revisit this the day something needs After=dots-ask.service, or the day
    # startup grows a step worth waiting on. Store::open already folds every
    # transcript on the way up and nothing waits for it today.
    systemd.user.services.dots-ask = {
      Unit = {
        Description = "dots-ask: the AI side pane daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session-pre.target" ];
      };
      Service = {
        Type = "exec";
        ExecStart = lib.getExe dots-ask;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
