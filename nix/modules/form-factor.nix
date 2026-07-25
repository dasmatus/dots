# Hardware form-factor detection + performance tuning. Reads the
# nixos-facter report (nix/hosts.nix) at eval time to classify the machine
# as laptop / desktop / server / vm, then adjusts CPU governor + EPP,
# thermals, power/suspend, scheduler/I/O, and a handful of services per
# form factor. The committed facter.json stub ({}) leaves detection off
# and defaults to "desktop" so the flake stays green without a report.
#
# Detection order (first match wins):
#   1. dots.formFactor set explicitly           → use it (override)
#   2. report.virtualisation != "none"          → "vm"
#   3. report.hardware.system.form_factor       → laptop/desktop/server map
#   4. fallback                                  → "desktop"
#
# Override the auto choice on a single machine WITHOUT touching facter.json
# by setting dots.formFactor in the installed clone's config, e.g. a
# desktop that facter misreports as a laptop:
#   { dots.formFactor = "desktop"; }
{
  config,
  lib,
  ...
}:
let
  report = config.hardware.facter.report;
  virt = report.virtualisation or "none";
  ffRaw = (report.hardware.system or { }).form_factor or null;

  # SMBIOS chassis type names (hwinfo smbios.c) folded into a coarse class.
  # hwinfo's int.c also sets form_factor to "laptop"/"desktop" directly, but
  # real reports occasionally carry the raw chassis name instead, so both are
  # mapped here. The set-membership is case-insensitive via toLower.
  chassisClass =
    name:
    let
      n = lib.toLower name;
      laptops = [
        "laptop"
        "notebook"
        "portable"
        "sub notebook"
        "subnotebook"
        "hand held"
        "handheld"
        "lunch box"
      ];
      servers = [
        "main server chassis"
        "rack mount chassis"
        "raid chassis"
        "sealed-case pc"
        "multi-system chassis"
        "server"
      ];
    in
    if builtins.elem n laptops then
      "laptop"
    else if builtins.elem n servers then
      "server"
    else
      "desktop";

  auto =
    if virt != "none" then
      "vm"
    else if ffRaw != null then
      chassisClass ffRaw
    else
      "desktop";

  # Resolve the user-facing enum: "auto" defers to facter detection, any
  # other value is an explicit override. We never write back to the option
  # (that would recurse on config.dots.formFactor); downstream logic reads
  # this local binding instead.
  formFactor = if config.dots.formFactor == "auto" then auto else config.dots.formFactor;

  isLaptop = formFactor == "laptop";
  isDesktop = formFactor == "desktop";
  isServer = formFactor == "server";
  isVm = formFactor == "vm";
  # Everything that isn't a laptop or VM behaves as "always-on, no battery":
  # desktops and servers share the performance-first profile.
  isAlwaysOn = isDesktop || isServer;

  # EPP values: power-balanced knob on intel_pstate / amd_pstate. Written via
  # a tmpfiles `w` rule (write-only, no path creation) since NixOS has no
  # first-class EPP option; re-applied on every `systemd-tmpfiles --create`.
  epp = if isLaptop then "balance_performance" else "performance";

  # cpuFreqGovernor: powerManagement.* — powersave on laptop (the governor
  # stays permissive; EPP does the real tuning on modern pstate drivers),
  # performance on desktop/server, schedutil on VMs (no frequency scaling on
  # vCPUs, but schedutil avoids the cpufreq_userspace trap).
  governor =
    if isLaptop then
      "powersave"
    else if isVm then
      "schedutil"
    else
      "performance";

  # I/O scheduler: bfq favours interactive fairness on laptop disks; none
  # (deadline for nvme) on servers/desktops/VMs where the host/hypervisor
  # already arbitrates. Set via udev rule, not a NixOS option.
  ioScheduler = if isLaptop then "bfq" else "none";
in
{
  options.dots.formFactor = lib.mkOption {
    type = lib.types.enum [
      "laptop"
      "desktop"
      "server"
      "vm"
      "auto"
    ];
    default = "auto";
    description = ''
      Hardware form factor driving the performance/power profile. "auto"
      (the default) classifies from the nixos-facter report: virtualisation
      → "vm", else hardware.system.form_factor → laptop/desktop/server,
      else "desktop". Set explicitly to override detection without editing
      facter.json (e.g. a misdetected desktop).
    '';
  };

  config = {
    # ── CPU governor / EPP ──────────────────────────────────────────
    powerManagement.cpuFreqGovernor = governor;

    # EPP write rule: `w` writes the attribute on every tmpfiles create and
    # silently skips paths that don't exist (e.g. CPUs offline at activation,
    # or VMs with no pstate driver). The glob covers all CPUs including those
    # hotplugged later.
    systemd.tmpfiles.rules = [
      "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - ${epp}"
    ];

    # ── Thermals ─────────────────────────────────────────────────────
    # thermald is Intel-only and meaningless on VMs; laptops and desktops
    # both benefit. Servers in a rack are assumed to have external control.
    services.thermald.enable = isLaptop || isDesktop;

    # ── Power / suspend ──────────────────────────────────────────────
    # power-profiles-daemon (PPD) is the modern replacement for TLP and the
    # only one of the two NixOS allows simultaneously. PPD maps its profiles
    # onto the pstate EPP knob we set above; enabling it on laptops lets the
    # DE (and `powerprofilesctl`) shift on the fly. Off on server/VM: no
    # battery and no D-Bus session to drive it.
    services.power-profiles-daemon.enable = isLaptop;

    # Lid switch via the modern settings/Login shape (the flat lidSwitch/
    # lidSwitchExternalPower options emit a deprecation trace but still map
    # here; use the structured form directly to stay forward of the rename).
    services.logind.settings.Login =
      let
        action = if isLaptop then "suspend" else "ignore";
      in
      {
        HandleLidSwitch = action;
        HandleLidSwitchExternalPower = action;
      };

    # Hard-mask the sleep/suspend/hibernate targets on always-on machines so
    # nothing — not logind idle, not a stray `systemctl suspend` from a
    # service — can put a server/desktop tower to sleep. mkForce so a stray
    # enabling elsewhere doesn't silently revive it.
    systemd.targets.sleep.enable = lib.mkIf isAlwaysOn (lib.mkForce false);
    systemd.targets.suspend.enable = lib.mkIf isAlwaysOn (lib.mkForce false);
    systemd.targets.hibernate.enable = lib.mkIf isAlwaysOn (lib.mkForce false);
    systemd.targets.hybrid-sleep.enable = lib.mkIf isAlwaysOn (lib.mkForce false);

    # ── Scheduler / I/O ──────────────────────────────────────────────
    # Lower swappiness on VMs (host owns memory pressure) and on always-on
    # machines (predictable reclaim); keep the laptop default so suspend-
    # resume and memory pressure behave normally on battery.
    boot.kernel.sysctl."vm.swappiness" = lib.mkDefault (
      if isVm then
        10
      else if isAlwaysOn then
        20
      else
        60
    );

    # bfq on laptops (interactive fairness for the desktop workload), none
    # elsewhere (nvme deadline is the kernel default and fine under load).
    services.udev.extraRules = ''
      ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-9]n[0-9]", ATTR{queue/scheduler}="${ioScheduler}"
    '';

    # fstrim timer: only on real disks. VMs often sit on copy-on-write or
    # thin-provisioned backings where TRIM is a no-op or actively harmful
    # (qcow2, zfs). Laptops/desktops/servers with SSDs benefit.
    services.fstrim.enable = !isVm;

    # ── Services ─────────────────────────────────────────────────────
    # Bluetooth off on server/VM (no radios, no point loading the stack).
    # NixOS auto-disables bluetooth.hardware when enable=false, so this is
    # the single knob.
    hardware.bluetooth.enable = isLaptop || isDesktop;

    # Wi-Fi power-save on laptops (extends battery; the AP tolerates it on
    # modern networks), disabled elsewhere. NetworkManager option — applies
    # to the wpa_supplicant/iwd backend alike.
    networking.networkmanager.wifi.powersave = isLaptop;
  };
}
