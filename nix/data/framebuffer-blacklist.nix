# Legacy framebuffer drivers refused outright, ported from secureblue's
# blacklist-framebuffer.conf (`reference/secureblue-framebuffer.conf` in
# this project's SDD notes), itself inherited from Ubuntu's kmod package
# (see that file's own "Upstream:" pointer) with secureblue's own
# additions layered on. Only the entries upstream actually blacklists are
# here — the ones Fedora already blacklists elsewhere are left commented
# out in the reference file and are not repeated here.
#
# Kept in its own file rather than folded into module-blacklist.nix
# because it carries a DIFFERENT license and a different, multi-party
# copyright list (ProFUSION, Intel, Lucas De Marchi, Alexey Gladkov, Pedro
# Pedruzzi, Michal Marek, plus secureblue's own additions) — see
# REUSE.toml, where this path is LGPL-2.1-or-later rather than either
# secureblue's usual Apache-2.0 or this repo's default AGPL-3.0-only.
#
# Consumed by nix/modules/system/hardening.nix alongside
# module-blacklist.nix, rendered the same way (`install <mod> /bin/false`
# via boot.extraModprobeConfig).
[
  "cyber2000fb"
  "cyblafb"
  "gx1fb"
  "hgafb"
  "lxfb"
  "matroxfb_base"
  "neofb"
  "pm2fb"
  "s1d13xxxfb"
  "sisfb"
  "vesafb"
  "vfb"
  "vt8623fb"
  "udlfb"
]
