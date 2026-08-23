# Random Wallhaven wallpaper on login + hourly (user service/timer).
# Sets the wallpaper via wallpaper-tui (which drives awww) under Hyprland
# and gsettings under GNOME; customize the query with WH_*
# environment variables on the service.
{ pkgs, lib, ... }:

let
  wallhavenRandom = pkgs.writeShellScriptBin "wallhaven-random-wallpaper" ''
    set -euo pipefail

    # Wallhaven query knobs — pinned SFW-only. purity/categories are the
    # API's 3-bit masks: sfw/sketchy/nsfw and general/anime/people; an
    # invalid apikey (anything non-empty that isn't real) makes the API 401.
    WH_API_KEY=""
    WH_SEED=""
    WH_PURITY="100"
    WH_CATS="111"
    WH_ATLEAST="1920x1080"

    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/wallhaven"
    mkdir -p "$CACHE_DIR"

    url="https://wallhaven.cc/api/v1/search?purity=$WH_PURITY&categories=$WH_CATS&atleast=$WH_ATLEAST&sorting=random"
    if [ -n "$WH_API_KEY" ]; then
      url="$url&apikey=$WH_API_KEY"
    fi
    if [ -n "$WH_SEED" ]; then
      url="$url&seed=''${WH_SEED// /%20}"
    fi

    # .data[].path is already an absolute https://w.wallhaven.cc/... URL
    full_url="$(${pkgs.curl}/bin/curl -fsSL "$url" | ${pkgs.jq}/bin/jq -r '.data[0].path')"
    if [ -z "$full_url" ] || [ "$full_url" = "null" ]; then
      echo "Failed to pick a wallpaper from Wallhaven." >&2
      exit 1
    fi

    ext="''${full_url##*.}"
    case "$ext" in jpg | jpeg | png | webp | gif) ;; *) ext=jpg ;; esac
    img_path="$CACHE_DIR/current.$ext"

    tmp_path="$(mktemp "$CACHE_DIR/.wallhaven_current.XXXXXX.$ext")"
    trap 'rm -f "$tmp_path"' EXIT
    ${pkgs.curl}/bin/curl -fsSL "$full_url" -o "$tmp_path"
    mv -f "$tmp_path" "$img_path"
    trap - EXIT

    if [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v wallpaper-tui > /dev/null 2>&1; then
      # Route through wallpaper-tui so the hourly random pick also re-tints
      # borders/GTK/Qt/icons from the new wallpaper, and so the awww call
      # lives in one place. The '*' output means every output; --restore on
      # login re-applies the declarative eDP-1 default, so random picks stay
      # session-only by design.
      wallpaper-tui --output '*' "$img_path"
      echo "Set wallpaper via wallpaper-tui (Hyprland): $img_path"
      exit 0
    fi

    if command -v gsettings > /dev/null 2>&1; then
      uri="file://$img_path"
      gsettings set org.gnome.desktop.background picture-uri "$uri"
      gsettings set org.gnome.desktop.background picture-uri-dark "$uri"
      gsettings set org.gnome.desktop.background picture-options 'scaled'
      echo "Set wallpaper via gsettings (GNOME/Mutter): $img_path"
      exit 0
    fi

    echo "Could not set wallpaper: missing wallpaper-tui/gsettings." >&2
    exit 1
  '';
in
{
  home.packages = [ wallhavenRandom ];

  systemd.user.services.wallhaven-wallpaper = {
    Unit = {
      Description = "Set random Wallhaven wallpaper";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe wallhavenRandom}";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.timers.wallhaven-wallpaper = {
    Unit.Description = "Periodic random Wallhaven wallpaper";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
