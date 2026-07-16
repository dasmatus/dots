# Fedora's Microsoft-signed shim + MokManager, extracted untouched from the
# distro RPM (kojipkgs URLs are immutable, so the pin is stable). The signed
# LiveISO ships this shim as /EFI/BOOT/BOOTX64.EFI; it chainloads our
# MOK-signed grubx64.efi — see scripts/sign-iso.sh for the whole chain.
{
  stdenvNoCC,
  fetchurl,
  rpmextract,
}:
stdenvNoCC.mkDerivation {
  pname = "shim-signed";
  version = "15.8-3";

  src = fetchurl {
    url = "https://kojipkgs.fedoraproject.org/packages/shim/15.8/3/x86_64/shim-x64-15.8-3.x86_64.rpm";
    hash = "sha256-KJWNdTM8QrA0G3J6K2l+3wLwz67Bjb0lrmLJqBZPqr4=";
  };

  nativeBuildInputs = [ rpmextract ];

  unpackPhase = ''
    rpmextract "$src"
  '';

  installPhase = ''
    install -Dm444 boot/efi/EFI/fedora/shimx64.efi "$out/shimx64.efi"
    install -Dm444 boot/efi/EFI/fedora/mmx64.efi "$out/mmx64.efi"
  '';
}
