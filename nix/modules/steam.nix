# Steam — enabled when a real graphics controller is present in the
# nixos-facter report (nix/hosts.nix reads the same report). "Real" means a
# consumer/workstation GPU vendor: NVIDIA (0x10de), AMD/ATI (0x1002) or Intel
# (0x8086). That list excludes server BMC chips (ASPEED 0x1a03) and VM
# virtual graphics (virtio-gpu 0x1b36, Bochs 0x1234, QXL), so Steam stays off
# on headless servers and ordinary VMs. The committed {} facter stub leaves
# graphics_card empty, so detection returns false and the flake stays green
# without a report — same trick form-factor.nix uses to default to "desktop".
#
# A GPU-passthrough VM is the one deliberate exception: the passed-through
# card's real vendor id shows up in the guest report, so Steam turns on there
# too, which is what you want for a gaming VM.
#
# Override the auto choice on a single machine WITHOUT touching facter.json
# by setting dots.steam.enable explicitly in the installed clone's config:
#   { dots.steam.enable = true; }   # force on  (e.g. a passthrough VM you
#                                  #             want Steam on regardless)
#   { dots.steam.enable = false; }  # force off (e.g. an iGPU-only laptop
#                                  #             you don't game on)
# Mirrors the dots.formFactor override pattern in nix/modules/form-factor.nix.
{
  config,
  lib,
  ...
}:
let
  report = config.hardware.facter.report;

  # PCI vendor ids as facter reports them (decimal, not hex — see nix/hosts.nix:
  # 4318 == 0x10de). These three are the only consumer/workstation GPU vendors;
  # every other display-controller vendor in a facter report is either a server
  # BMC or a virtual GPU, neither of which is worth enabling Steam for.
  realGpuVendors = [
    4318 # NVIDIA        (0x10de)
    4098 # AMD / ATI     (0x1002) — covers APU iGPUs AND discrete Radeons
    32902 # Intel        (0x8086) — covers iGPUs AND Arc dGPUs
  ];

  hasDesktopGpu = builtins.any (card: builtins.elem (card.vendor.value or 0) realGpuVendors) (
    report.hardware.graphics_card or [ ]
  );

  # Resolve the user-facing knob: "auto" defers to facter detection, any other
  # value is an explicit override. We never write back to the option (that would
  # recurse on config.dots.steam.enable); the config block reads this local
  # binding instead — same shape as `formFactor` in form-factor.nix.
  steamEnabled =
    if config.dots.steam.enable == "auto" then hasDesktopGpu else config.dots.steam.enable;
in
{
  options.dots.steam.enable = lib.mkOption {
    type = lib.types.enum [
      "auto"
      true
      false
    ];
    default = "auto";
    description = ''
      Whether to enable Steam. "auto" (the default) enables it when the
      nixos-facter report lists a real graphics card (NVIDIA, AMD or Intel),
      skipping servers, ordinary VMs and the {} stub. Set explicitly to
      true/false to override detection without editing facter.json.
    '';
  };

  config = lib.mkIf steamEnabled {
    programs.steam = {
      enable = true;
      # Open the firewall for Steam Remote Play (streaming to/from another
      # machine) and for LAN game-content transfers (pulling an install from
      # another machine on the same network instead of re-downloading).
      remotePlay.openFirewall = true;
      localNetworkGameTransfers.openFirewall = true;
      # protontricks: Winetricks wrapper for Proton games — the standard
      # companion for installing native Windows dependencies (e.g. a game's
      # bundled redist) into a Proton prefix.
      protontricks.enable = true;
    };

    # NOTE: 32-bit graphics + 32-bit audio are NOT set here. nixpkgs' own
    # steam module (nixos/modules/programs/steam.nix) flips on
    # hardware.graphics.enable32Bit and services.pipewire.alsa.support32Bit
    # under `programs.steam.enable`, and desktop.nix already enables pipewire
    # alsa, so 32-bit audio wires up automatically. Restating them here would
    # just duplicate the upstream config block.
  };
}
