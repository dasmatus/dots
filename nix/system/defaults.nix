# Non-install-time parameters with defaults. flake.nix merges this file
# *under* nix/data/settings.nix:
#   settings = (import ./nix/system/defaults.nix) // (import ./nix/data/settings.nix);
# The installer TUI (rust/installer-tui/src/config.rs::settings_nix) rewrites
# the install answers (username/hostname/disks/swapSize/gitName/gitEmail)
# into settings.nix on the target, so anything it does not write must live
# here to survive an install — otherwise the installer would wipe it and the
# modules that read settings.<key> would lose their values on the next
# rebuild. Edit this file in the installed clone
# (~/Dokumente/.../dots/nix/system/defaults.nix) to change regional, desktop, boot,
# and network choices; it is git-tracked and travels with the user's clone,
# so edits persist across autoUpgrade (which only refreshes flake.lock, not
# this file).
{
  # Regional — consumed by nix/modules/system/core.nix.
  timezone = "Europe/Bratislava";
  locale = "de_DE.UTF-8";

  # Desktop environment — consumed by nix/modules/desktop/desktop.nix. The whole
  # system-level desktop block is gated on this being "hyprland"; "none" (or
  # any other value) skips it. NOTE: the Home Manager side (nix/home) is not
  # conditional on this — settings IS now passed to home-manager (users.nix
  # extraSpecialArgs), but only nix/home/shell/git.nix consumes it (for the git
  # identity); the home hyprland config is unconditional, so a non-"hyprland"
  # value here leaves it in place. Wire HM gating separately if a second
  # desktop is ever added.
  desktop = "hyprland";

  # Boot knobs — consumed by nix/modules/system/boot.nix.
  plymouthTheme = "rings";
  zswapCompressor = "842";
  # Merged (list-concat) with the hardening params in nix/modules/system/hardening.nix
  # and the serial-console params in nix/system/iso.nix (ISO only).
  bootKernelParams = [
    "quiet"
    "loglevel=3"
    "mitigations=auto"
    "zswap.writeback=0"
  ];

  # Proton account address, edited from the settings panel (SUPER+comma) and
  # read back by its Proton page to seed both logins. Nothing on the Nix side
  # consumes it: the page reads it through `global-settings dump`, the same
  # path every other row uses. Empty by default because the installer never
  # asks for it, and an empty field is what tells the page it is unconfigured.
  #
  # NB nix/home/proton/proton.nix carries the same address literally for the mail
  # account. Bridging this key through nix/modules/dots.nix would collapse the
  # two, at the cost of editing a working account, so they are separate.
  protonEmail = "";

  # Git commit-signing key override, edited from the settings panel. Empty
  # by default: nix/home/shell/git.nix currently hardcodes `signingkey` to the
  # Bitwarden-vault SSH key's public half and does not read this key yet, so
  # an empty default changes nothing. Wiring git.nix to consume it (falling
  # back to the current hardcoded path when empty) is left to the task that
  # rewires the settings panel's live-apply path.
  gitSigningKey = "";

  # Ollama HTTP endpoint, edited from the settings panel. nix/home/sandbox/triage.nix
  # is the first Nix-side consumer (exports it to `dots-sandbox triage`'s
  # optional assist layer); nix/system/hosts.nix's `services.ollama` itself
  # still just binds to the NixOS module's own default (127.0.0.1:11434),
  # which is what this default matches.
  aiOllamaEndpoint = "http://127.0.0.1:11434";

  # `dots-sandbox triage`'s optional assist layer — see
  # .superpowers/sdd/structured-fluttering-chipmunk/triage-contract.md.
  # Consulted ONLY for denials the pure heuristic table in
  # rust/dots-sandbox/src/triage.rs abstains on; never for anything the
  # table already resolved to allow/block. Off by default: a security tool
  # that silently starts consulting a model is a surprise, not an assist.
  # This flag is read solely by nix/home/sandbox/triage.nix, which exports it
  # (plus the two keys below) as DOTS_TRIAGE_ASSIST_* environment variables
  # for the `triage` subcommand. It has no bearing on `dots-sandbox run` —
  # the launcher every app start goes through — which reads none of the
  # DOTS_TRIAGE_* variables and imports no ollama-touching module; grep
  # rust/dots-sandbox/src/{launch,main}.rs for "ollama" or "DOTS_TRIAGE" to
  # confirm that separation instead of trusting this comment.
  triageAssistEnable = false;

  # Model `dots-sandbox triage --assist` asks. Already one of aiOllamaModels
  # above, so it is already pulled by `services.ollama.loadModels` and
  # already persisted under aiOllamaModelsDir (/var/lib/ollama/models) —
  # enabling triageAssistEnable downloads nothing new. Configurable past
  # this default; the assist layer must not hardcode it.
  triageAssistModel = "ornith:9b";

  # SearXNG endpoint the assist layer's `searxng_search` tool calls, subject
  # to the wrapper's hard privacy gate (queries containing a `$HOME` path or
  # any absolute path are rejected before the HTTP call — see the contract's
  # "search tool" section; enforced in the wrapper, not by asking the model
  # nicely). Matches nix/modules/services/searxng.nix's bind_address/port —
  # that module owns the actual `searx` service (its systemd unit is named
  # `searx`, NOT `searxng`); this is only the address a client dials.
  triageAssistSearxngEndpoint = "http://127.0.0.1:8888";

  # Window manager — edited from the settings panel. Values here match
  # nix/home/desktop/hyprland.nix's current hardcoded `general`/`input`/`animations`
  # block exactly, so this addition is a no-op on rebuild: hyprland.nix does
  # not read these keys yet, and wiring it to do so is left to the task that
  # owns the settings panel's live-apply path. wmFollowMouse is a bool here
  # even though Hyprland's own `input.follow_mouse` is an int (0/1/2/3); the
  # settings panel only offers on/off, so `true` maps to Hyprland's default
  # `1` and `false` to `0` once that wiring lands.
  wmGapsIn = 5;
  wmGapsOut = 15;
  wmBorderSize = 2;
  wmFollowMouse = true;
  wmAnimations = true;
  wmLayout = "dwindle";

  # Network — consumed by nix/modules/system/network.nix. wifiBackend is one of
  # "wpa_supplicant" | "iwd"; reversePathFilter is one of "loose" | "strict"
  # (or false) — see networking.firewall.checkReversePath in nixpkgs.
  wifiBackend = "wpa_supplicant";
  reversePathFilter = "loose";

  # AI tooling — bridged to options.dots.ai.* by nix/modules/dots.nix. The
  # installer TUI "AI" screen rewrites the three enable toggles (aiClaude,
  # aiCodex, aiOllama) into settings.nix on the target; the models list +
  # models dir stay here as user-editable defaults (manageable via the
  # dots.ai.* NixOS options). nix/system/hosts.nix gates services.ollama on
  # dots.ai.ollama and reads dots.ai.ollamaModels / ollamaModelsDir.
  aiClaude = true;
  aiCodex = true;
  aiOllama = true;
  aiOllamaModels = [
    "ornith:9b"
    "gemma4:e4b"
  ];
  # /var/lib/ollama is persisted by nix/modules/system/impermanence.nix, so models
  # survive the tmpfs root wipe instead of re-downloading every boot.
  aiOllamaModelsDir = "/var/lib/ollama/models";

  # Install-answer stash root — bridged to options.dots.paths.stateDir by
  # nix/modules/dots.nix. nix/data/facter.json + nix/data/settings.nix are symlinked
  # here by the first-login dots-clone service (nix/home/base/dots-repo.nix), and
  # impermanence.nix bind-mounts /persist over it.
  dotsStateDir = "/var/lib/dots";
  system.stateVersion = "26.11";
}
