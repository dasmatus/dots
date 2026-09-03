# Non-install-time parameters with defaults. flake.nix merges this file
# *under* nix/settings.nix:
#   settings = (import ./nix/defaults.nix) // (import ./nix/settings.nix);
# The installer TUI (rust/installer-tui/src/config.rs::settings_nix) rewrites
# the install answers (username/hostname/disks/swapSize/gitName/gitEmail)
# into settings.nix on the target, so anything it does not write must live
# here to survive an install — otherwise the installer would wipe it and the
# modules that read settings.<key> would lose their values on the next
# rebuild. Edit this file in the installed clone
# (~/Dokumente/.../dots/nix/defaults.nix) to change regional, desktop, boot,
# and network choices; it is git-tracked and travels with the user's clone,
# so edits persist across autoUpgrade (which only refreshes flake.lock, not
# this file).
{
  # Regional — consumed by nix/modules/core.nix.
  timezone = "Europe/Bratislava";
  locale = "de_DE.UTF-8";

  # Desktop environment — consumed by nix/modules/desktop.nix. The whole
  # system-level desktop block is gated on this being "hyprland"; "none" (or
  # any other value) skips it. NOTE: the Home Manager side (nix/home) is not
  # conditional on this — settings IS now passed to home-manager (users.nix
  # extraSpecialArgs), but only nix/home/git.nix consumes it (for the git
  # identity); the home hyprland config is unconditional, so a non-"hyprland"
  # value here leaves it in place. Wire HM gating separately if a second
  # desktop is ever added.
  desktop = "hyprland";

  # Boot knobs — consumed by nix/modules/boot.nix.
  plymouthTheme = "rings";
  zswapCompressor = "842";
  # Merged (list-concat) with the hardening params in nix/modules/hardening.nix
  # and the serial-console params in nix/iso.nix (ISO only).
  bootKernelParams = [
    "quiet"
    "loglevel=3"
    "mitigations=auto"
  ];

  # Proton account address, edited from the settings panel (SUPER+comma) and
  # read back by its Proton page to seed both logins. Nothing on the Nix side
  # consumes it: the page reads it through `global-settings dump`, the same
  # path every other row uses. Empty by default because the installer never
  # asks for it, and an empty field is what tells the page it is unconfigured.
  #
  # NB nix/home/proton.nix carries the same address literally for the mail
  # account. Bridging this key through nix/modules/dots.nix would collapse the
  # two, at the cost of editing a working account, so they are separate.
  protonEmail = "";

  # Network — consumed by nix/modules/network.nix. wifiBackend is one of
  # "wpa_supplicant" | "iwd"; reversePathFilter is one of "loose" | "strict"
  # (or false) — see networking.firewall.checkReversePath in nixpkgs.
  wifiBackend = "wpa_supplicant";
  reversePathFilter = "loose";

  # AI tooling — bridged to options.dots.ai.* by nix/modules/dots.nix. The
  # installer TUI "AI" screen rewrites the three enable toggles (aiClaude,
  # aiCodex, aiOllama) into settings.nix on the target; the models list +
  # models dir stay here as user-editable defaults (manageable via the
  # dots.ai.* NixOS options). nix/hosts.nix gates services.ollama on
  # dots.ai.ollama and reads dots.ai.ollamaModels / ollamaModelsDir.
  aiClaude = true;
  aiCodex = true;
  aiOllama = true;
  aiOllamaModels = [
    "ornith:9b"
    "gemma4:e4b"
  ];
  # /var/lib/ollama is persisted by nix/modules/impermanence.nix, so models
  # survive the tmpfs root wipe instead of re-downloading every boot.
  aiOllamaModelsDir = "/var/lib/ollama/models";

  # Install-answer stash root — bridged to options.dots.paths.stateDir by
  # nix/modules/dots.nix. nix/facter.json + nix/settings.nix are symlinked
  # here by the first-login dots-clone service (nix/home/dots-repo.nix), and
  # impermanence.nix bind-mounts /persist over it.
  dotsStateDir = "/var/lib/dots";
}
