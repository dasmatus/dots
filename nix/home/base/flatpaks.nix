# Declarative Flatpak. Every GUI app this profile installs, as a Flathub ref.
#
# This reverses the migration nix/home/base/pkgs.nix's header describes. That
# migration turned flatpaks into nixpkgs derivations; this turns the GUI half
# back, and goes further by pulling in apps that were never flatpaks here
# (the browsers, the editor, the mail client, the vault client).
#
# Why back: the profile's portable half is aimed at a host this repo does not
# build. That host is a Fedora Atomic / secureblue desktop, where Flatpak *is*
# the app delivery mechanism and a nix-installed GUI app is the foreign object.
# A flatpak also arrives with its own bubblewrap confinement and its own portal
# plumbing, which is the sandboxing story that survives on a host with no
# microvm host to launch into (see nix/home/profiles/session.nix and the
# `wrapSandboxed` note in flake/home.nix).
#
# USER installation only. nix-flatpak's home-manager module writes to
# ~/.local/share/flatpak and never touches the system installation, so this
# needs no root and cannot collide with the host distribution's own
# system-wide flatpaks.
#
# ── The apps that did NOT follow ────────────────────────────────────────────
# Three because Flathub has no package for them (checked against the Flathub
# API, not assumed):
#   - kitty has no Flathub package (io.github.kovidgoyal.kitty is 404). A
#     terminal emulator in a flatpak sandbox is also the one case where the
#     sandbox is actively wrong: its whole job is spawning host commands.
#   - claude-desktop has no Flathub package (com.anthropic.claude is 404).
#     Upstream ships a .deb only, which is why
#     nix/packages/claude-desktop.nix repackages it.
#   - haveno has no Flathub package (exchange.haveno.Haveno is 404). Upstream
#     ships a signed AppImage, wrapped in nix/home/base/pkgs.nix.
#
# And one that Flathub *does* package, deliberately declined:
#   - Betterbird. eu.betterbird.Betterbird exists, but taking it would force
#     home-manager's thunderbird module off (its `package` is typed
#     `package`, not `nullOr package`, so the configure-without-installing
#     trick the browsers and Zed use is unavailable), and that module being
#     off deletes nix/home/proton/proton-calendar.nix's entire output. See
#     nix/home/proton/proton.nix for the full argument.
#
# These four stay nixpkgs/AppImage packages. Nothing else in the GUI set does.
#
# ── Why two remotes ─────────────────────────────────────────────────────────
# secureblue ships `flathub-verified`, a filtered view of Flathub carrying
# only developer-verified apps, meaning apps published by the software's
# actual authors rather than by a third party. Most of this list is
# available there and is pinned to it.
#
# Five are not, so they come from the unfiltered `flathub` remote, and that is
# a deliberate, narrow widening of what this machine will install from: a
# non-verified ref means Flathub has not confirmed the publisher is upstream.
# Every entry below carries an explicit `origin`, so which remote an app
# trusts is a property you can read off the line rather than a lookup order
# that silently changes when a remote is added. Nothing falls back.
{
  lib,
  pkgs,
  dots,
  ...
}:
{
  services.flatpak = {
    # The switch the rest of this file hangs off. Without it nothing below runs.
    # No warning, no error, just nothing. nix-flatpak's home-manager module
    # wraps its ENTIRE `config` in `lib.mkIf config.services.flatpak.enable`,
    # and declares that option with
    # `default = args.osConfig.services.flatpak.enable or false`. On NixOS that
    # default reads the SYSTEM-level `services.flatpak.enable` through
    # home-manager's `osConfig` argument. A standalone build (flake/home.nix)
    # has no `osConfig` at all, and Nix's `or` swallows the whole failed
    # selection chain rather than just a missing attribute, so the default is
    # false: the remotes, packages and overrides below all evaluate perfectly,
    # emit no unit, and the machine silently has no browsers. That is not a
    # module bug. The option arrived in nix-flatpak 2b53cf77 ("Add
    # compatibility with stand-alone home-manager"), replacing a bare
    # `osConfig` reference that used to ABORT a standalone eval. The
    # compatibility it added is an eval that succeeds by doing nothing, which
    # is why this failed silently for as long as it did.
    #
    # It belongs HERE and not in flake/home.nix, even though the foreign host
    # is the only machine running this today. The 25 refs, both remotes and the
    # five overrides already live in this shared file, which
    # nix/home/profiles/portable.nix imports on both entry points, and
    # nix/modules/system/users.nix lists this very module in `sharedModules`
    # with the comment "the home-manager module drives the USER flatpak
    # installation, so this stays on the HM side even on NixOS". Parking the
    # switch in the host-specific file would separate it from the list it
    # switches on, which is exactly the shape of the bug it fixes.
    #
    # On NixOS, nix/modules/desktop/desktop.nix now also sets the
    # SYSTEM-level `services.flatpak.enable` (nixpkgs' own bare flatpak
    # module, not this one) so these apps' exports/share join the system
    # XDG_DATA_DIRS too, not only the user one. That is a separate switch
    # from this `enable`, which stays here and stays true regardless: this
    # file is still what drives the USER flatpak installation (the packages,
    # remotes and overrides below), on NixOS and on the foreign host alike,
    # and the system-level one has no packages/overrides list of its own to
    # read. On secureblue XDG_DATA_DIRS already begins with
    # ~/.local/share/flatpak/exports/share regardless of either switch.
    enable = true;

    # Both remotes are declared so a machine that has neither (any host that is
    # not secureblue) still resolves every ref below. Re-declaring a remote
    # that already exists is a no-op, so this does not disturb the
    # `flathub-verified` remote secureblue set up.
    remotes = [
      {
        name = "flathub-verified";
        location = "https://dl.flathub.org/repo/flathub-verified.flatpakrepo";
      }
      {
        name = "flathub";
        location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
      }
    ];

    # Left at the default (false) on purpose. This profile lands on machines
    # that already have hand-installed flatpaks. This one had Flatseal, and
    # `true` would uninstall every app not named below on the first switch.
    # The cost of the safe default is that removing a line here stops managing
    # an app rather than removing it; `flatpak uninstall --user <id>` is the
    # deliberate second step.
    uninstallUnmanaged = false;

    update.auto = {
      enable = true;
      onCalendar = "weekly";
    };

    packages = [
      # ── Verified publisher (flathub-verified) ──────────────────────────
      # GNOME-adjacent tools
      {
        appId = "ca.desrt.dconf-editor";
        origin = "flathub-verified";
      }
      {
        appId = "com.mattjakeman.ExtensionManager";
        origin = "flathub-verified";
      }
      {
        appId = "org.gnome.Firmware";
        origin = "flathub-verified";
      }
      # Flatseal, the flatpak permission editor. Dropped by the migration
      # away from flatpaks as "obsolete"; it is not obsolete now that every
      # GUI app here is a flatpak again, and it is the tool for inspecting
      # what the overrides in this file actually granted. Already installed
      # by hand on this machine, so declaring it adopts it rather than
      # adding anything.
      {
        appId = "com.github.tchx84.Flatseal";
        origin = "flathub-verified";
      }

      # Browsers. Both were nixpkgs packages with home-manager modules
      # driving their profiles (nix/home/apps/{brave,librewolf}.nix); see
      # those files for what survived the move and what could not.
      {
        appId = "com.brave.Browser";
        origin = "flathub-verified";
      }
      {
        appId = "io.gitlab.librewolf-community";
        origin = "flathub-verified";
      }
      # The browser chooser that sits in front of them.
      {
        appId = "re.sonny.Junction";
        origin = "flathub-verified";
      }

      # Vault client (GUI half; the `rbw` CLI in
      # nix/home/apps/bitwarden.nix stays native, see there).
      {
        appId = "com.bitwarden.desktop";
        origin = "flathub-verified";
      }

      # Apps
      {
        appId = "dev.vencord.Vesktop";
        origin = "flathub-verified";
      }
      {
        appId = "io.frama.tractor.carburetor";
        origin = "flathub-verified";
      }
      {
        appId = "md.obsidian.Obsidian";
        origin = "flathub-verified";
      }
      {
        appId = "org.libreoffice.LibreOffice";
        origin = "flathub-verified";
      }
      {
        appId = "org.onionshare.OnionShare";
        origin = "flathub-verified";
      }
      {
        appId = "org.torproject.torbrowser-launcher";
        origin = "flathub-verified";
      }
      {
        appId = "org.keepassxc.KeePassXC";
        origin = "flathub-verified";
      }
      {
        appId = "chat.simplex.simplex";
        origin = "flathub-verified";
      }
      {
        appId = "org.gnome.World.PikaBackup";
        origin = "flathub-verified";
      }
      {
        appId = "org.prismlauncher.PrismLauncher";
        origin = "flathub-verified";
      }
      {
        appId = "page.tesk.Refine";
        origin = "flathub-verified";
      }

      # ── Unfiltered Flathub (publisher NOT verified) ────────────────────
      # Each of these 404s on flathub-verified but exists on flathub. They
      # are listed together rather than sorted in among the rest so the
      # weaker provenance is visible at a glance instead of buried.
      {
        appId = "io.mpv.Mpv";
        origin = "flathub";
      }
      {
        appId = "com.transmissionbt.Transmission";
        origin = "flathub";
      }
      {
        appId = "org.bleachbit.BleachBit";
        origin = "flathub";
      }
      {
        appId = "org.signal.Signal";
        origin = "flathub";
      }
      {
        appId = "dev.zed.Zed";
        origin = "flathub";
      }
    ]
    # Newelle exists only to front the ollama cloud model, so it follows the
    # same dots.ai.ollama gate its dconf settings do in
    # nix/home/base/pkgs.nix. With ollama off there is no backend for it to
    # talk to.
    ++ lib.optional dots.ai.ollama {
      appId = "io.github.qwersyk.Newelle";
      origin = "flathub-verified";
    };

    # Portal-level grants that the default manifests do not carry and that
    # this config's use of the app depends on. Anything not listed here keeps
    # upstream's own permissions. These are additions, not a policy rewrite.
    overrides = {
      # secureblue's own measured deny-by-default baseline (`ujust
      # harden-flatpak`, ~/.local/share/flatpak/overrides/global.save),
      # ported verbatim from
      # .superpowers/sdd/snug-herding-cupcake/reference/flatpak-global-deny.ini
      # — see docs/superpowers/specs/2026-09-08-hardening-design.md's
      # "Flatpak global deny" section for where it was measured from. This is
      # the confinement every Flatpak on this machine gets by default; the
      # per-app overrides below layer additional grants on top of it, each
      # with its own reason, exactly as `flatpaks.nix:277`'s (now this
      # comment's own) observation about a per-app grant re-opening a global
      # deny already predicted.
      #
      # This baseline existed ONLY on the foreign secureblue host until now,
      # written by its own `ujust` tooling. tokyonight had none, so every
      # Flatpak here ran on upstream's own permissive manifest — this is the
      # single biggest confinement win in the whole hardening project.
      global = {
        Context = {
          # !home/!host/etc deny the REAL host filesystem outside each app's
          # own ~/.var/app/<id> sandbox (which Flatpak always grants
          # regardless of this list) — this does not touch what an app
          # keeps in its own persisted directory.
          filesystems = [
            "!host-etc"
            "!/mnt"
            "!~/.bash_profile"
            "!~/.bashrc"
            "!/run/media"
            "!home"
            "!/media"
            "!/home"
            "!/var"
            "!/run"
            "!/var/home"
            "!host"
            # Kept per ruling R5: secureblue grants exactly this token so its
            # LD_PRELOAD'd hardened_malloc allocator (below) is reachable
            # inside the sandbox, and Phase B turns that same allocator on
            # for tokyonight (nix/modules/system/hardening.nix's
            # `environment.memoryAllocator.provider = "graphene-hardened"`).
            # Dropping it breaks every Flatpak's LD_PRELOAD the same way
            # dropping it would on secureblue.
            "host-os:ro"
          ];
          # network and ipc denied globally; every app below that genuinely
          # needs the internet gets `shared = [ "network" ]` back explicitly,
          # each with its own one-line reason — see the per-app overrides.
          shared = [
            "!ipc"
            "!network"
          ];
          sockets = [
            "!cups"
            "!gpg-agent"
            "!inherit-wayland-socket"
            "!pcsc"
            "!pulseaudio"
            "!session-bus"
            "!ssh-auth"
            "!system-bus"
            "wayland"
            "!x11"
          ];
          devices = [
            "!all"
            "dri"
            "!input"
            "!kvm"
            "!shm"
            "!usb"
          ];
          features = [
            "!bluetooth"
            "!canbus"
            "!devel"
            "!multiarch"
            "!per-app-dev-shm"
          ];
          persistent = [ "." ];
        };
        # Every name here is forced to `none` regardless of what an app's own
        # manifest declares as a `--talk-name`/`--own-name` finish-arg — this
        # does not touch xdg-desktop-portal access (`org.freedesktop.portal.*`
        # is proxied unconditionally by Flatpak's own sandbox setup,
        # independent of the blanket `!session-bus`/`!system-bus` denial
        # above), only the broader, less-audited D-Bus surface secureblue
        # measured as worth closing per-name.
        "Session Bus Policy" = {
          "org.kde.kpasswdserver" = "none";
          "com.canonical.Unity" = "none";
          "org.kde.kconfig.notify" = "none";
          "org.gnome.Software" = "none";
          "io.missioncenter.MissionCenter.Gatherer" = "none";
          "org.freedesktop.impl.portal.PermissionStore" = "none";
          "org.gnome.ControlCenter" = "none";
          "org.cinnamon.ScreenSaver" = "none";
          "org.kde.*" = "none";
          "org.gnome.Shell.Screenshot" = "none";
          "org.freedesktop.Tracker3.Writeback" = "none";
          "org.kde.StatusNotifierWatcher" = "none";
          "org.gtk.vfs.*" = "none";
          "org.kde.kiod5" = "none";
          "org.kde.kded5" = "none";
          "org.kde.kwalletd6" = "none";
          "org.kde.JobViewServer" = "none";
          "org.gnome.SessionManager" = "none";
          "org.kde.kwalletd5" = "none";
          "com.canonical.indicator.application" = "none";
          "org.freedesktop.Notifications" = "none";
          "org.kde.kiod6" = "none";
          "org.kde.kded6" = "none";
          "org.gnome.Mutter.IdleMonitor.*" = "none";
          "org.gnome.SettingsDaemon" = "none";
          "org.kde.KGlobalSettings" = "none";
          "org.freedesktop.secrets" = "none";
          "org.kde.kwin.Screenshot" = "none";
          "org.gnome.Settings" = "none";
          "org.gnome.ScreenSaver" = "none";
          "org.xfce.ScreenSaver" = "none";
          "ca.desrt.dconf" = "none";
          "org.kde.kpasswdserver6" = "none";
          "org.mate.ScreenSaver" = "none";
          "org.freedesktop.Flatpak" = "none";
          "org.gnome.SettingsDaemon.MediaKeys" = "none";
          "com.canonical.Unity.LauncherEntry" = "none";
          "org.freedesktop.ScreenSaver" = "none";
          "org.freedesktop.PowerManagement" = "none";
          "org.a11y.Bus" = "none";
          "org.freedesktop.FileManager1" = "none";
          "com.canonical.AppMenu.Registrar" = "none";
        };
        "System Bus Policy" = {
          "org.bluez" = "none";
          "org.freedesktop.UPower" = "none";
          "org.freedesktop.network1" = "none";
          "org.freedesktop.UDisks2" = "none";
          "org.freedesktop.Avahi" = "none";
          "org.freedesktop.Avahi.*" = "none";
          "org.freedesktop.fwupd" = "none";
          "org.freedesktop.locale1" = "none";
          "org.freedesktop.portable1" = "none";
          "org.freedesktop.import1" = "none";
          "org.freedesktop.hostname1" = "none";
          "org.freedesktop.timedate1" = "none";
          "org.freedesktop.home1" = "none";
          "org.freedesktop.resolve1" = "none";
          "org.freedesktop.machine1" = "none";
          "org.freedesktop.oom1" = "none";
          "org.freedesktop.systemd1" = "none";
          "org.freedesktop.sysupdate1" = "none";
          "org.freedesktop.LogControl1" = "none";
          "org.freedesktop.NetworkManager" = "none";
          "org.freedesktop.login1" = "none";
          "org.freedesktop.timesync1" = "none";
        };
        Environment = {
          # Matches secureblue's own line, unconditionally safe: Electron
          # ignores it entirely on X11 and picks Wayland automatically under
          # a Wayland session, so this only ever helps.
          ELECTRON_OZONE_PLATFORM_HINT = "auto";
          # secureblue's own value is a literal Fedora Atomic path
          # (/usr/lib64/glibc-hwcaps/...) that does not exist on NixOS, so it
          # is NOT ported verbatim — that would silently no-op exactly like
          # every other missing LD_PRELOAD target does (ld.so warns and
          # ignores, never a hard failure). This interpolates the real
          # store path of the SAME allocator Phase B turns on system-wide
          # (nix/modules/system/hardening.nix), on the same reasoning R5
          # gives for keeping `host-os:ro` above: with the real host
          # filesystem (and therefore /nix/store) reachable inside the
          # sandbox, the sandboxed glibc's plain LD_PRELOAD lookup (ordinary
          # glibc behavior, unrelated to NixOS's own `ld-nix.so.preload`
          # patch that mediates every OTHER process on this machine) finds
          # the same hardened allocator every native process uses. Verify on
          # real hardware once this lands: a Flatpak's own bundled runtime
          # ships its own glibc, and it is empirically Flatpak's own
          # `host-os` NixOS handling — not this repo — that decides whether
          # /nix/store is actually visible at this path inside the sandbox.
          LD_PRELOAD = "${pkgs.graphene-hardened-malloc}/lib/libhardened_malloc.so";
        };
      };

      # Brave is launched with `--load-extension=<store path>` (see
      # nix/home/apps/brave.nix), and a flatpak cannot read /nix/store by
      # default. Read-only: the browser only ever needs to load the unpacked
      # extension dir, never to write there.
      "com.brave.Browser".Context.filesystems = [
        "/nix/store:ro"
        # The host's /etc, read-only, so Brave can read the managed policy
        # files this repo installs at /etc/brave/policies/managed. The Flathub
        # wrapper (/app/bin/brave) looks for them under
        # /run/host/etc/brave/policies and /run/host/etc/static/brave/policies
        # and symlinks whatever it finds into the sandbox's own /etc, so the
        # policies are simply absent without this.
        #
        # It has to be stated per-app because secureblue's global override
        # (~/.local/share/flatpak/overrides/global, written by
        # `ujust harden-flatpak`) carries `!host-etc`. Verified that a per-app
        # positive grant does re-open it over that global deny.
        #
        # Deliberately host-etc and not `host`: this widens Brave to the host's
        # /etc read-only, which is the narrowest token the wrapper's lookup path
        # can be satisfied by. On the NixOS side none of this applies.
        # nix/modules/desktop/desktop.nix installs the same policies through
        # environment.etc and Brave is not a flatpak there.
        "host-etc:ro"
      ];
      # The global deny above strips `network` from every app; a browser
      # with no network access is not a browser. Every entry below re-grants
      # it for exactly this reason — a browser, a chat client, a download
      # tool, or anything else whose entire purpose is talking to the
      # internet — never for an app that merely COULD use it.
      "com.brave.Browser".Context.shared = [ "network" ];
      # Three apps keep their configuration where home-manager renders it,
      # under $HOME, and reach it through an out-of-store symlink planted in
      # the per-app root (see the bottom of each module). The symlink is
      # useless without a matching grant: a flatpak resolves symlinks INSIDE
      # its own mount namespace, so a link pointing at ~/.librewolf dangles
      # unless ~/.librewolf is bound in. Read-write, because all three
      # rewrite their own profile constantly: search.json.mozlz4, message
      # indexes, settings.json edited from the UI.
      # Firefox 67+ mints a NEW profile per installation and records it as
      # [Install<hash>] in profiles.ini, ignoring Profile0's Default=1. Against
      # a home-manager profile that is fatal in a quiet way: LibreWolf starts,
      # looks configured, and is running a blank profile with none of the
      # prefs or extensions.packages XPIs below. Observed here as nine
      # throwaway <random>.default-default directories, one per launch, each
      # containing only times.json.
      #
      # Making profiles.ini writable does NOT fix it. That only lets the
      # dedicated-profile migration record its choice, which it then does.
      # MOZ_LEGACY_PROFILES=1 is the documented switch that turns the
      # migration off and restores "use the profile marked Default=1".
      # Verified both ways on this host: without it, one new profile per
      # launch and default/ stays empty; with it, zero new profiles, no
      # installs.ini, no [Install] section, and default/ fills with the 38
      # files a real session writes.
      "io.gitlab.librewolf-community".Environment.MOZ_LEGACY_PROFILES = "1";
      "io.gitlab.librewolf-community".Context.shared = [ "network" ];

      "io.gitlab.librewolf-community".Context.filesystems = [
        # No ~/.librewolf entry: the profile is not there any more. It lives in
        # the flatpak's own persisted directory now (see configPath in
        # nix/home/apps/librewolf.nix), which the sandbox always has, so the
        # old grant pointed at a path that no longer exists.
        # The store, read-only. Still required after the profile moved, but
        # for a different reason than before: it is no longer a directory
        # symlink that has to be traversed, it is the per-FILE symlinks inside
        # the profile. home-manager writes user.js, search.json.mozlz4 and each
        # extensions/*.xpi as links into /nix/store, and a flatpak resolves
        # symlinks inside its own mount namespace, so without this the profile
        # directory is present and every managed file in it is unreadable.
        "/nix/store:ro"
      ];
      # Zed also needs the code it edits, hence the second entry. Network:
      # language-server/extension downloads and its AI features.
      "dev.zed.Zed".Context.shared = [ "network" ];
      "dev.zed.Zed".Context.filesystems = [
        "~/.config/zed"
        "~/Dokumente"
        # The language servers and formatters nix/home/apps/zed.nix installs
        # into the profile. Read-only: Zed executes them, never writes them.
        "/nix/store:ro"
      ];
      # Obsidian's vault lives in ~/Dokumente/Obsidian Vault (the tree
      # nix/home/base/dokumente.nix materializes), which is outside the
      # host-filesystem access its manifest asks for. Left WITHOUT a network
      # grant, deliberately: local markdown editing needs none, and
      # community-plugin/sync features that would want it are opt-in from
      # inside the app — the safer default is to make the user notice and
      # grant it via Flatseal rather than have it silently already open.
      "md.obsidian.Obsidian".Context.filesystems = [
        "~/Dokumente/Obsidian Vault"
      ];
      # Pika Backup reads its own JSON state and writes borg repositories on
      # removable media. Network: it also supports a remote/cloud borg
      # repository, not only the local ~/run/media case above.
      "org.gnome.World.PikaBackup".Context.shared = [ "network" ];
      "org.gnome.World.PikaBackup".Context.filesystems = [
        "/run/media"
      ];

      # ── Network-only widenings ──────────────────────────────────────────
      # No filesystem/other grant needed, only the global deny's `!network`
      # reopened, each for the one-line reason given.
      # Vault sync with Bitwarden's own servers.
      "com.bitwarden.desktop".Context.shared = [ "network" ];
      # Discord client — the entire app is a chat client.
      "dev.vencord.Vesktop".Context.shared = [ "network" ];
      # Tor onion-routing client (carburetor) — needs the network to reach
      # the Tor network in the first place.
      "io.frama.tractor.carburetor".Context.shared = [ "network" ];
      # OnionShare shares files/hosts services over Tor; the whole point.
      "org.onionshare.OnionShare".Context.shared = [ "network" ];
      # Downloads and updates the actual Tor Browser bundle.
      "org.torproject.torbrowser-launcher".Context.shared = [ "network" ];
      # Encrypted chat client — needs the network to reach SimpleX servers.
      "chat.simplex.simplex".Context.shared = [ "network" ];
      # Minecraft launcher: fetches versions/mods and talks to Mojang auth.
      "org.prismlauncher.PrismLauncher".Context.shared = [ "network" ];
      # BitTorrent client — needs the network to reach peers/trackers.
      "com.transmissionbt.Transmission".Context.shared = [ "network" ];
      # Encrypted chat client — needs the network to reach Signal's servers.
      "org.signal.Signal".Context.shared = [ "network" ];
      # Browses and installs GNOME Shell extensions from extensions.gnome.org.
      "com.mattjakeman.ExtensionManager".Context.shared = [ "network" ];
      # Checks and downloads firmware updates from the LVFS over fwupd.
      "org.gnome.Firmware".Context.shared = [ "network" ];
    }
    # Newelle's whole purpose is talking to an LLM backend (ollama, in this
    # config's case) — it needs the network share the same way its package
    # entry above is gated on dots.ai.ollama.
    // lib.optionalAttrs dots.ai.ollama {
      "io.github.qwersyk.Newelle".Context.shared = [ "network" ];
    };
  };
}
