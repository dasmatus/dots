# systemd for the parts of the system that still had a non-systemd answer,
# measured against LosOS Desktop (github.com/losos-project/losos-desktop,
# nixos/modules/{network,services}.nix), which uses systemd for everything it
# can. What this module takes from it, and what it leaves alone on purpose:
#
# Taken:
#   - systemd-resolved as the system resolver, with NetworkManager handing it
#     per-link DNS instead of writing /etc/resolv.conf itself.
#   - journald storing the journal on disk, stated rather than inherited.
#   - systemd-sysext / systemd-confext, merged at boot when an extension is
#     dropped into /var/lib/extensions or /var/lib/confexts
#     (impermanence.nix persists both).
#   - systemd-homed for the login account and systemd-sysusers for system
#     users, in homed.nix.
#
# Left alone, each for a reason recorded where it lives:
#   - NetworkManager, not networkd: the Proton VPN app (nix/home/proton)
#     drives NetworkManager connections and has no networkd backend.
#   - chrony with NTS, not timesyncd: timesyncd speaks plain SNTP with no
#     authentication (network.nix).
#   - Limine, not systemd-boot: systemd-boot's installer needs the
#     /etc/machine-id that impermanence does not keep (boot.nix).
#   - systemd-coredump off: hardening.nix turns core dumps off entirely.
#
# scripts/systemd-upstream.sh and .github/workflows/systemd-upstream.yml keep
# watch on upstream systemd releases against the version this flake pins.
{ ... }:
{
  # DNS-over-TLS opportunistically: encrypted where the server offers it, plain
  # where it does not, so a captive portal or a VPN-pushed resolver still
  # answers. "true" would refuse those outright.
  #
  # mDNS and LLMNR stay off, unlike LosOS. Both answer on the local link, and
  # firewalld's drop zone (hardening.nix) would drop the queries anyway; there
  # is no avahi here either, so nothing on the LAN learns this host's name.
  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSOverTLS = "opportunistic";
      MulticastDNS = false;
      LLMNR = false;
    };
  };
  networking.networkmanager.dns = "systemd-resolved";

  # /var/log is persisted by impermanence.nix, so "auto" would already write to
  # disk once /var/log/journal exists. Stated so it does not hinge on that
  # directory having been created.
  services.journald.settings.Journal.Storage = "persistent";

  # Not in NixOS's default unit set, so pulled in and wired to sysinit.target
  # here, the same as upstream's own [Install] section. With no extension
  # installed both are skipped by their own ConditionDirectoryNotEmpty=.
  systemd.additionalUpstreamSystemUnits = [
    "systemd-sysext.service"
    "systemd-confext.service"
  ];
  systemd.services.systemd-sysext.wantedBy = [ "sysinit.target" ];
  systemd.services.systemd-confext.wantedBy = [ "sysinit.target" ];
  systemd.tmpfiles.settings."10-dots-extensions" = {
    "/var/lib/extensions".d.mode = "0755";
    "/var/lib/confexts".d.mode = "0755";
  };
}
