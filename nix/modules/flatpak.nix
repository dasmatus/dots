# Declarative flatpaks (declarative-flatpak): /var/lib/flatpak is rebuilt from
# this list on activation and weekly; anything installed imperatively — incl.
# via GNOME Software, which is therefore left disabled — gets wiped.
# flathub-verified is the same Flathub repo added twice and narrowed to the
# "verified" subset, so provenance is enforced per-app. GNOME core apps come
# from here instead of nixpkgs (services.gnome.core-apps is off in desktop.nix).
{ pkgs, ... }:
let
  # Apps present in the verified subset (checked via flatpak remote-ls)
  verified = [
    "ca.desrt.dconf-editor"
    "com.github.tchx84.Flatseal"
    "com.ktechpit.torrhunt"
    "com.mattjakeman.ExtensionManager"
    "dev.qwery.AddWater"
    "dev.vencord.Vesktop"
    "io.frama.tractor.carburetor"
    "io.github.diegopvlk.Cine"
    "io.github.justinrdonnelly.bouncer"
    "io.github.mpobaschnig.Vaults"
    "io.github.qwersyk.Newelle"
    "io.gitlab.librewolf-community"
    "md.obsidian.Obsidian"
    "org.gnome.Firmware"
    "org.libreoffice.LibreOffice"
    "org.onionshare.OnionShare"
    "org.torproject.torbrowser-launcher"
    # hyprland binds run these two via `flatpak run` — undeclared = wiped
    "org.keepassxc.KeePassXC"
    "org.flameshot.Flameshot"
    # GNOME core apps
    "org.gnome.baobab"
    "org.gnome.Calculator"
    "org.gnome.Calendar"
    "org.gnome.Characters"
    "org.gnome.clocks"
    "org.gnome.Connections"
    "org.gnome.Contacts"
    "org.gnome.Decibels"
    "org.gnome.Epiphany"
    "org.gnome.font-viewer"
    "org.gnome.Logs"
    "org.gnome.Loupe"
    "org.gnome.Maps"
    "org.gnome.Music"
    "org.gnome.Papers"
    "org.gnome.Showtime"
    "org.gnome.SimpleScan"
    "org.gnome.Snapshot"
    "org.gnome.TextEditor"
    "org.gnome.Weather"
  ];
  # Not (yet) verified on Flathub — installed from the full remote
  unverified = [
    "chat.simplex.simplex"
    "com.transmissionbt.Transmission"
    "io.gitlab.persiangolf.voicegen"
    "org.bleachbit.BleachBit"
    "org.briarproject.Briar"
    "org.gnome.World.PikaBackup"
    "org.prismlauncher.PrismLauncher"
    "org.signal.Signal"
    "org.virt_manager.virt-manager"
    "page.tesk.Refine"
  ];
  # Haveno ships no hosted flatpak repo, only release bundles; the sha256 is
  # cross-checked against the release's 1.8.0-reto.hashes file.
  havenoBundle = pkgs.fetchurl {
    url = "https://github.com/retoaccess1/haveno-reto/releases/download/v1.8.0-reto/haveno-v1.8.0-linux-x86_64.flatpak";
    hash = "sha256-ViVYFOqO2lnBjo4wqT2Ax/1Er+iuKMica5/MeS+iUNU=";
  };
in
{
  services.flatpak = {
    enable = true;
    remotes = {
      flathub = "https://dl.flathub.org/repo/flathub.flatpakrepo";
      flathub-verified = "https://dl.flathub.org/repo/flathub.flatpakrepo";
    };
    # remote-add has no subset flag; narrow the remote before installs run
    # (FLATPAK_SYSTEM_DIR points at the staged installation here).
    preInstallCommand = "flatpak --system remote-modify --subset=verified flathub-verified";
    packages =
      map (id: "flathub-verified:app/${id}//stable") verified
      ++ map (id: "flathub:app/${id}//stable") unverified
      ++ [ ":${havenoBundle}" ];
  };
}
