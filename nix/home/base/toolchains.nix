# The language toolchains (Rust, C/C++, Haskell) as a home-manager module.
#
# Extracted from nix/home/base/pkgs.nix, which used to compute
# `languageToolchains` inline, so a profile that wants the compilers but not
# that file's GUI inhabitants (Haveno, scrot, the Nerd Font) can install the
# same env without dragging them along — that is what the server profile
# (nix/home/profiles/server.nix) imports this for. pkgs.nix imports it too, so
# the portable/session builds are unchanged and there is still exactly ONE
# definition of the toolchain list (flake/languages.nix).
#
# The same editor-parity guarantee holds exactly as before: Neovim's
# nixvim lsp.servers.hls and Zed's `haskell` extension both find the
# identical binaries by bare name, because this env is what puts them on PATH.
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # The language toolchains, evaluated out of the SAME devenv module
  # flake/devenv.nix imports, see flake/languages.nix for what is in it and
  # why. `mkConfig` runs devenv's module system and stops there; it does not
  # build a shell, so nothing about `devenv.root`, the git hooks or
  # `enterShell` is involved, and none of that file's assertions are forced.
  #
  # `pkgs` is this evaluation's own instance (the system one on NixOS via
  # `useGlobalPkgs`, flake/home.nix's on a foreign host), not the flake's, so
  # the toolchains are built from the same nixpkgs as everything else in the
  # profile rather than a second instance that merely happens to agree.
  #
  # `config.packages` is devenv's public list of what the environment puts on
  # PATH, but it is not only OUR packages: devenv's own top-level adds
  # pkg-config unconditionally, and `processes` resolves a process manager
  # (process-compose) whether or not anything declares a process. Those belong
  # to `devenv up`, not to a user profile, so the baseline is evaluated once
  # with no modules and subtracted, leaving exactly what flake/languages.nix
  # contributed. Doing it by subtraction rather than by an exclusion list
  # means a future devenv that adds something else to its baseline does not
  # quietly grow the profile.
  #
  # (The baseline eval is module-system only, no derivations are built for it,
  # and `subtractLists` compares derivations by output path, so this is a
  # cheap set difference, not a rebuild.)
  toolchains = inputs.devenv.lib.mkConfig {
    inherit pkgs inputs;
    modules = [ ../../../flake/languages.nix ];
  };
  devenvBaseline = inputs.devenv.lib.mkConfig {
    inherit pkgs inputs;
    modules = [ ];
  };

  # One derivation rather than splicing `toolchains.packages` straight into
  # `home.packages`, for one concrete reason: devenv's language modules
  # deliberately list overlapping packages (clang-tools comes from both
  # `languages.c` and `languages.cplusplus`, clang from `cplusplus` and from
  # the Rust linker driver), which costs nothing on a shell's PATH but is a
  # hard error in home-manager's profile buildEnv, which does not ignore
  # collisions. devenv builds its own profile with `ignoreCollisions` for the
  # same reason; this is that, under a name that says where it came from.
  #
  # NB the join is how the profile is assembled, not a layer anything has to
  # know about: an editor or script looking for `clangd` still finds
  # ~/.nix-profile/bin/clangd exactly as before.
  languageToolchains = pkgs.buildEnv {
    name = "dots-language-toolchains";
    paths = lib.subtractLists devenvBaseline.packages toolchains.packages;
    ignoreCollisions = true;
  };
in
{
  home.packages = [ languageToolchains ];
}
