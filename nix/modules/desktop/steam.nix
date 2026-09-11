# Steam — enabled when a real graphics controller is present in the
# nixos-facter report (nix/system/hosts.nix reads the same report). "Real" means a
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
# Mirrors the dots.formFactor override pattern in nix/modules/system/form-factor.nix.
#
# dots.steam.millennium (default true, while Steam itself is enabled) loads
# Millennium (SteamClientHomebrew/Millennium), a theme/plugin loader for the
# Steam client, by overriding `programs.steam.package`. See the comment on
# that `package` assignment below for why it's a package override rather than
# upstream's global overlay, and how the override composes with the nixpkgs
# steam module's own `.override` call.
#
# ── Why Steam stays native, not a Flatpak ───────────────────────────────────
#
# Every other GUI app on this machine is a Flathub ref now
# (nix/home/base/flatpaks.nix). Steam was considered for the same move
# (com.valvesoftware.Steam exists on Flathub) and rejected, for one specific,
# checked reason: `dots.steam.millennium` above patches `programs.steam` by
# overriding `package` with a `pkgs.callPackage` of Millennium's own
# `steam.nix` (see that assignment's comment for the full mechanics) — a
# Nix-level package override that has no Flatpak equivalent. Millennium
# itself patches the Steam client's own JS/CSS at the package level; a
# Flatpak's `programs.steam` escape hatch does not exist, and Millennium's
# own install method (a script that writes into the running client's own
# install dir) fights a Flatpak's read-only `/app`. Moving to
# `com.valvesoftware.Steam` would have silently dropped working theming with
# no equivalent way to get it back. That is reason enough on its own; do not
# re-litigate this without a real Flatpak-side Millennium story in hand.
#
# It also cannot be hardened the way every native package in Phase B's
# curated overlay is: `programs.steam` wraps Valve's prebuilt proprietary
# binaries in an FHS environment (`buildFHSEnv`/bubblewrap) with no source
# in this closure, so the Clang/CFI/ThinLTO flags
# (docs/superpowers/specs/2026-09-08-hardening-design.md, "Phase B") have
# nothing to recompile. That is permanent, not a gap to close later.
#
# Steam has already forced three other hardening exceptions, each ruled
# separately and NOT to be "tidied up" here:
#   - `ia32_emulation` stays on (ruling R11) — the Steam runtime is 32-bit.
#   - XWayland stays enabled (ruling R23) — Steam is an X11-only client.
#   - `joydev` stays out of the kernel module blacklist (ruling R25a) —
#     blacklisting the joystick layer under an enabled Steam is
#     self-defeating; gamepads stop enumerating.
# Steam also does NOT inherit hardened_malloc (see
# nix/modules/system/hardening.nix's allocator comment): its FHS environment
# gets its own private /etc with no `ld-nix.so.preload`, so the patched
# glibc that reads that file everywhere else on this machine finds nothing
# to preload inside Steam's sandbox. Worth knowing, not a defect to chase.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  report = config.hardware.facter.report;

  # PCI vendor ids as facter reports them (decimal, not hex — see nix/system/hosts.nix:
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

  # Both default OFF. `remotePlay.openFirewall`/`localNetworkGameTransfers.
  # openFirewall` are the ONLY open inbound ports on a machine whose
  # hardening.nix otherwise sets allowedTCPPorts = [], allowedUDPPorts = []
  # and trustedInterfaces = [] — the entire rest of the firewall is
  # deny-by-default. Both are opt-in Steam features (streaming to another
  # device; copying installs between machines on the same LAN); leaving them
  # off costs nothing to a user who does not use either, and turning either
  # back on is one boolean away rather than a feature deletion.
  options.dots.steam.remotePlay.openFirewall = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Open the firewall for Steam Remote Play (streaming to/from another
      device). Off by default — this is the only inbound hole this option
      controls; see `dots.steam.localNetworkGameTransfers.openFirewall` for
      the other one.
    '';
  };

  options.dots.steam.localNetworkGameTransfers.openFirewall = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Open the firewall for Steam's LAN game-content transfers (pulling an
      install from another machine on the same network instead of
      re-downloading it). Off by default; see
      `dots.steam.remotePlay.openFirewall` for the other inbound hole this
      module can open.
    '';
  };

  config = lib.mkIf steamEnabled {
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = config.dots.steam.remotePlay.openFirewall;
      localNetworkGameTransfers.openFirewall =
        config.dots.steam.localNetworkGameTransfers.openFirewall;
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
      # overrides *this call's arguments* — steam, openssl,
      # pkgsi686Linux, lib, millennium, extraPkgs, extraLibraries, extraEnv,
      # extraProfile — not steam's own package attrs. So the module's
      # `.override` re-invokes
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
      # nix/modules/system/impermanence.nix).
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

    # AppArmor, in the style of nix/modules/system/apparmor.nix's own
    # per-app profiles — same abstractions, same attach_disconnected +
    # mediate_deleted flags — but declared here rather than threaded into
    # that file, since this is the one profile in the whole config that
    # needs `config.programs.steam.package` (the resolved FHS wrapper) to
    # attach to at all.
    #
    # COMPLAIN ONLY, and not a placeholder to graduate later without new
    # evidence: `programs.steam.package` is a `buildFHSEnv`/bubblewrap
    # wrapper (`pkgs/by-name/st/steam`, `pname = "steam"`), the exact same
    # shape as `nix/home/base/pkgs.nix`'s Haveno wrapper that
    # nix/modules/system/apparmor.nix's own `dots-haveno` profile is kept at
    # complain for. `bin/steam` unshares a new mount namespace and re-execs
    # its actual game/client processes from generic FHS paths inside it
    # (plus a Proton prefix and arbitrary downloaded vendor binaries PER
    # GAME on top of that), none of which a profile anchored to the
    # wrapper's own `/nix/store/**` attachment can see or authorize. This is
    # Steam's OWN version of the identical structural gap, one order of
    # magnitude wider given how much of it is vendor code this repo does not
    # control at all. Attempting enforce here without dedicated evidence
    # repeats incident `9b069e8` (hardening.nix) at a scale that incident
    # only hinted at — denying a namespacing-heavy binary its own exec chain
    # takes the whole client down, not just the parts a per-app profile
    # meant to narrow.
    security.apparmor.policies.dots-steam = {
      state = "complain";
      profile = ''
        abi <abi/4.0>,

        include <tunables/global>

        profile dots-steam "${config.programs.steam.package}/bin/steam" flags=(attach_disconnected,mediate_deleted) {
          include <abstractions/base>
          include <abstractions/nameservice>
          include <abstractions/fonts>
          include <abstractions/freedesktop.org>
          include <abstractions/dbus-session-strict>
          include <abstractions/audio>
          include <abstractions/X>
          include <abstractions/mesa>
          include <abstractions/opengl>
          include <abstractions/p11-kit>
          include <abstractions/ssl_certs>
          include <abstractions/user-tmp>

          /nix/store/** rm,
          /nix/store/**/bin/* ix,
          /nix/store/**/libexec/** ix,

          # The FHS/bubblewrap sandbox every launch builds, and Proton's own
          # user-namespace use inside it.
          userns,
          mount,
          umount,
          pivot_root,

          network inet stream,
          network inet6 stream,
          network inet dgram,
          network inet6 dgram,
          network netlink raw,
          network unix stream,
          network unix dgram,

          owner @{HOME}/** rwkl,
          owner /tmp/** rwkl,
          @{run}/user/@{uid}/** rwkl,
          @{PROC}/@{pid}/** r,
          /sys/devices/** r,
          /dev/dri/* rw,
          /dev/shm/** rwk,

          # Controllers. `joydev` deliberately stays out of the kernel
          # module blacklist (ruling R25a) for exactly this — an enabled
          # Steam with no path to its own gamepads is self-defeating.
          /dev/input/** rw,
          /dev/uinput rw,
          /dev/hidraw* rw,

          deny @{HOME}/.ssh/** mrwklx,
          deny @{HOME}/.gnupg/** mrwklx,
          deny @{HOME}/.local/share/rbw/** mrwklx,
          deny @{HOME}/.config/rbw/** mrwklx,
          deny @{run}/user/@{uid}/rbw/** mrwklx,
        }
      '';
    };
  };
}
