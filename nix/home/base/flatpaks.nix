# Declarative Flatpak — every GUI app this profile installs, as a Flathub ref.
#
# This reverses the migration nix/home/base/pkgs.nix's header describes. That
# migration turned flatpaks into nixpkgs derivations; this turns the GUI half
# back, and goes further by pulling in apps that were never flatpaks here
# (the browsers, the editor, the mail client, the vault client).
#
# Why back: the profile's portable half is aimed at a host this repo does not
# build — a Fedora Atomic / secureblue desktop, where Flatpak *is* the app
# delivery mechanism and a nix-installed GUI app is the foreign object. A
# flatpak also arrives with its own bubblewrap confinement and its own portal
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
#   - kitty            — no Flathub package exists (io.github.kovidgoyal.kitty
#                        is 404). A terminal emulator in a flatpak sandbox is
#                        also the one case where the sandbox is actively
#                        wrong: its whole job is spawning host commands.
#   - claude-desktop   — no Flathub package (com.anthropic.claude is 404).
#                        Upstream ships a .deb only, which is why
#                        nix/packages/claude-desktop.nix repackages it.
#   - haveno           — no Flathub package (exchange.haveno.Haveno is 404).
#                        Upstream ships a signed AppImage, wrapped in
#                        nix/home/base/pkgs.nix.
#
# And one that Flathub *does* package, deliberately declined:
#   - Betterbird      — eu.betterbird.Betterbird exists, but taking it would
#                       force home-manager's thunderbird module off (its
#                       `package` is typed `package`, not `nullOr package`,
#                       so the configure-without-installing trick the browsers
#                       and Zed use is unavailable), and that module being off
#                       deletes nix/home/proton/proton-calendar.nix's entire
#                       output. See nix/home/proton/proton.nix for the full
#                       argument.
#
# These four stay nixpkgs/AppImage packages. Nothing else in the GUI set does.
#
# ── Why two remotes ─────────────────────────────────────────────────────────
# secureblue ships `flathub-verified`, a filtered view of Flathub carrying
# only developer-verified apps — apps published by the software's actual
# authors rather than by a third party. Most of this list is available there
# and is pinned to it.
#
# Five are not, so they come from the unfiltered `flathub` remote, and that is
# a deliberate, narrow widening of what this machine will install from: a
# non-verified ref means Flathub has not confirmed the publisher is upstream.
# Every entry below carries an explicit `origin`, so which remote an app
# trusts is a property you can read off the line rather than a lookup order
# that silently changes when a remote is added. Nothing falls back.
{
  lib,
  dots,
  ...
}:
{
  services.flatpak = {
    # The switch the rest of this file hangs off. Without it nothing below runs
    # — no warning, no error, just nothing. nix-flatpak's home-manager module
    # wraps its ENTIRE `config` in `lib.mkIf config.services.flatpak.enable`,
    # and declares that option with
    # `default = args.osConfig.services.flatpak.enable or false`. On NixOS that
    # default reads the SYSTEM-level `services.flatpak.enable` through
    # home-manager's `osConfig` argument. A standalone build (flake/home.nix)
    # has no `osConfig` at all, and Nix's `or` swallows the whole failed
    # selection chain rather than just a missing attribute, so the default is
    # false: the remotes, packages and overrides below all evaluate perfectly,
    # emit no unit, and the machine silently has no browsers. That is not a
    # module bug — the option arrived in nix-flatpak 2b53cf77 ("Add
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
    # switches on — which is exactly the shape of the bug it fixes.
    #
    # NB the NixOS side of this repo never sets the SYSTEM-level
    # `services.flatpak.enable`, so there these apps install into the user
    # installation but their exports/share is not added to XDG_DATA_DIRS.
    # That is a one-line follow-up in nix/modules/, not a reason to scope this
    # to the foreign host: on secureblue XDG_DATA_DIRS already begins with
    # ~/.local/share/flatpak/exports/share.
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
    # that already have hand-installed flatpaks — this one had Flatseal — and
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
      # Flatseal — the flatpak permission editor. Dropped by the migration
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
      # nix/home/apps/bitwarden.nix stays native — see there).
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
    # upstream's own permissions — these are additions, not a policy rewrite.
    overrides = {
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
        # `ujust harden-flatpak`) carries `!host-etc` — verified that a per-app
        # positive grant does re-open it over that global deny.
        #
        # Deliberately host-etc and not `host`: this widens Brave to the host's
        # /etc read-only, which is the narrowest token the wrapper's lookup path
        # can be satisfied by. On the NixOS side none of this applies —
        # nix/modules/desktop/desktop.nix installs the same policies through
        # environment.etc and Brave is not a flatpak there.
        "host-etc:ro"
      ];
      # Three apps keep their configuration where home-manager renders it,
      # under $HOME, and reach it through an out-of-store symlink planted in
      # the per-app root (see the bottom of each module). The symlink is
      # useless without a matching grant: a flatpak resolves symlinks INSIDE
      # its own mount namespace, so a link pointing at ~/.librewolf dangles
      # unless ~/.librewolf is bound in. Read-write, because all three
      # rewrite their own profile constantly — search.json.mozlz4, message
      # indexes, settings.json edited from the UI.
      "io.gitlab.librewolf-community".Context.filesystems = [
        "~/.librewolf"
        # The store, read-only -- required, and NOT for the same reason as
        # Brave's grant above. `mkOutOfStoreSymlink` cannot emit a direct link:
        # it works by placing a symlink IN the store whose target is the
        # out-of-store path. So what actually lands at
        # ~/.var/app/io.gitlab.librewolf-community/.librewolf is a three-hop
        # chain whose first two hops are store paths:
        #
        #   .../.librewolf -> /nix/store/...-home-manager-files/.var/app/.../.librewolf
        #                  -> /nix/store/...-hm_.librewolf
        #                  -> /home/matus/.librewolf
        #
        # A flatpak resolves symlinks inside its OWN mount namespace, so
        # granting just ~/.librewolf leaves hop 1 aimed at a /nix/store that is
        # not mounted in there. LibreWolf does not error on an unreadable
        # profile path -- it starts a fresh profile -- so the symptom is a
        # browser with none of its prefs and none of the extensions.packages
        # XPIs, and nothing in any log explaining it. The comment above about
        # ~/.librewolf needing to be bound in is true but insufficient; it
        # describes a one-hop link this mechanism never produces.
        "/nix/store:ro"
      ];
      # Zed also needs the code it edits, hence the second entry.
      "dev.zed.Zed".Context.filesystems = [
        "~/.config/zed"
        "~/Dokumente"
        # The language servers and formatters nix/home/apps/zed.nix installs
        # into the profile. Read-only: Zed executes them, never writes them.
        "/nix/store:ro"
      ];
      # Obsidian's vault lives in ~/Dokumente/Obsidian Vault (the tree
      # nix/home/base/dokumente.nix materializes), which is outside the
      # host-filesystem access its manifest asks for.
      "md.obsidian.Obsidian".Context.filesystems = [
        "~/Dokumente/Obsidian Vault"
      ];
      # Pika Backup reads its own JSON state and writes borg repositories on
      # removable media.
      "org.gnome.World.PikaBackup".Context.filesystems = [
        "/run/media"
      ];
    };
  };
}
