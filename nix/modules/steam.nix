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
#
# dots.steam.millennium (default true, while Steam itself is enabled) loads
# Millennium (SteamClientHomebrew/Millennium), a theme/plugin loader for the
# Steam client, by overriding `programs.steam.package`. See the comment on
# that `package` assignment below for why it's a package override rather than
# upstream's global overlay, and how the override composes with the nixpkgs
# steam module's own `.override` call.
{
  config,
  lib,
  pkgs,
  inputs,
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

  options.dots.steam.millennium = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Whether to load Millennium (SteamClientHomebrew/Millennium) by
      replacing `programs.steam.package`. Only takes effect while Steam
      itself is enabled (dots.steam.enable resolves to true).

      Turning this off later leaves behind the
      ~/.local/share/Steam/ubuntu12_{32,64}/libXtst.so.6 symlinks
      Millennium's profile script wrote, pointing at a store path the
      garbage collector eventually deletes. If the client misbehaves after
      disabling this, remove those symlinks and run `steam --reset`.
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

      # Millennium as a package override, not upstream's overlays.default or
      # their millennium-steam package: those pull in a whole Steam client
      # (and its FHS closure) built against upstream's own pinned nixpkgs,
      # two months behind ours, which would put an old 32-bit library set
      # under this repo's mesa32 — see the millennium input comment in
      # flake.nix. Upstream's packages/nix/steam.nix is a plain function over
      # `{ steam, openssl, pkgsi686Linux, lib, millennium, ... }`, so
      # callPackage'ing it against *this* `pkgs` keeps the client and every
      # FHS library on this repo's nixpkgs; only the small `millennium`
      # library (MIT) comes from the input's own pinned nixpkgs.
      #
      # How the merge survives the nixpkgs steam module: that module's
      # `programs.steam.package` option has an `apply` that calls
      # `.override (prev: …)` on whatever package this returns, to splice in
      # the graphics-driver libs (extraEnv/extraLibraries/extraPkgs). Because
      # callPackage wraps its result in `makeOverridable`, that `.override`
      # overrides *this call's arguments* — steam.nix, openssl,
      # pkgsi686Linux, millennium, extraPkgs, extraLibraries, extraEnv — not
      # steam's own package attrs. So the module's `.override` re-invokes
      # upstream's steam.nix with its extraEnv/extraLibraries/extraPkgs
      # threaded through, and steam.nix re-merges Millennium's libraries, env
      # and profile script around them. Neither side's additions are
      # dropped, and `extraProfile` survives untouched because the nixpkgs
      # module never sets it.
      #
      # Millennium's state — plugins, themes, and the hijacked
      # libXtst.so.6 symlinks its profile script rewrites on every launch —
      # lives under ~/.local/share/Steam, which persists: /home is a real
      # btrfs subvol, not routed through impermanence (see
      # nix/modules/impermanence.nix).
      package = lib.mkIf config.dots.steam.millennium (
        pkgs.callPackage "${inputs.millennium}/steam.nix" {
          millennium = inputs.millennium.packages.${pkgs.stdenv.hostPlatform.system}.millennium;
        }
      );
    };

    # NOTE: 32-bit graphics + 32-bit audio are NOT set here. nixpkgs' own
    # steam module (nixos/modules/programs/steam.nix) flips on
    # hardware.graphics.enable32Bit and services.pipewire.alsa.support32Bit
    # under `programs.steam.enable`, and desktop.nix already enables pipewire
    # alsa, so 32-bit audio wires up automatically. Restating them here would
    # just duplicate the upstream config block.
  };
}
