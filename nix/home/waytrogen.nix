# Waytrogen — GUI wallpaper setter for Wayland (nitrogen successor, Rust).
# Packaged in pkgs.nix and launched with `waytrogen --restore` from
# hyprland.nix exec-once so the last-chosen wallpaper is re-applied on login.
#
# This module only seeds its config — it does NOT manage it via
# xdg.configFile, because waytrogen's GUI writes `saved_wallpapers` back into
# config.json in-place, and xdg.configFile would deploy a read-only Nix-store
# symlink that breaks those saves. Instead, the activation script below writes
# a full, writable config.json on first run (or when the existing one still
# has wallpaper_folder == null, i.e. the unconfigured default), then leaves it
# alone so GUI picks persist across rebuilds.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDir = config.home.homeDirectory;

  # Seed config with @HOME@ placeholder for the one absolute path waytrogen
  # needs (it doesn't expand ~). Substituted with the real home dir in the
  # activation script so the file stays a diffable, byte-faithful JSON.
  seedConfig = "${./waytrogen-config.json}";
in
{
  home.activation.seedWaytrogen = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    cfg_dir="$HOME/.config/waytrogen"
    cfg_file="$cfg_dir/config.json"
    needs_seed=0
    if [[ ! -f "$cfg_file" ]]; then
      needs_seed=1
    elif ${pkgs.jq}/bin/jq -e '.wallpaper_folder == null' "$cfg_file" > /dev/null 2>&1; then
      needs_seed=1
    # Migration: re-seed when the existing config still carries the OLD
    # default folder (.../Wallpapers, pre-wh-restriction) so the picker scope
    # change propagates to already-deployed machines. Any other folder value
    # means the user customized it in the GUI — leave it alone.
    elif [[ $(${pkgs.jq}/bin/jq -r '.wallpaper_folder' "$cfg_file") == "${homeDir}/Dokumente/gitlab/personal/dots/Wallpapers" ]]; then
      needs_seed=1
    fi
    if [[ "$needs_seed" == 1 ]]; then
      $DRY_RUN_CMD mkdir -p "$cfg_dir"
      $DRY_RUN_CMD ${pkgs.gnused}/bin/sed "s|@HOME@|${homeDir}|g" ${seedConfig} > "$cfg_file"
    fi
  '';
}
