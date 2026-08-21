# HyprTile (https://hyprtile.org) — the fullscreen tile launcher / command
# center the desktop stack is converted to. It replaces the rofi drun
# launcher, the rofi power menu and the grim Print-screenshot with one
# Layer-Shell app driven by Hyprland IPC: SUPER+D opens the tile grid
# (page 1 apps, page 2 session/power), Print runs hyprtile-shotter, and
# hyprtile-wallpaperd is the wallpaper daemon (started by wallpaper-tui
# --restore at hyprland.start, or by hyprtile itself if not yet running —
# both share ~/.hyprtile/wallpaperd.pid).
#
# The flake-level package (flake/packages.nix, `nix build .#hyprtile`)
# builds only the pieces used here: launcher, wallpaperd, shotter,
# screener + small helper tools. hyprtilePkg arrives via extraSpecialArgs
# like wallpaperTui/hyprmon/settingsMenu.
#
# ~/.hyprtile/config.json is SEEDED, not symlinked: HyprTile's built-in
# tile editor and wallpaper-tui's config sync write it at runtime, so a
# store symlink would break saving. To reset to the declarative grid:
# rm ~/.hyprtile/config.json and re-activate (home-manager switch).
{
  hyprtilePkg,
  config,
  lib,
  pkgs,
  ...
}:
let
  # Tokyonight palette, matching waybar.nix / hyprlock (hyprland.nix).
  # Tile colors are "R,G,B" strings, overlay colors #RRGGBBAA — that split
  # is HyprTile's format, not a choice here.
  tokyonight = {
    bgRgb = "26,27,38"; # #1a1b26
    borderRgb = "41,46,66"; # #292e42
    blueRgb = "122,162,247"; # #7aa2f7
    yellowRgb = "224,175,104"; # #e0af68
  };
  tile = name: command: icon: color: {
    inherit name command icon;
    icon_color = color;
    bg = "#16161d";
    hov = "#292e42";
  };
  # Guarded lookup: wallpaper-tui's own defaults are currentOutput = "" and
  # outputs = { }, and a currentOutput naming an undeclared output must not
  # blow up home-manager eval with "attribute missing" — no wallpaper beats
  # no build. wallpaper flips to 0 when there is nothing to point at.
  wt = config.programs.wallpaper-tui;
  wallpaperPath =
    if wt.outputs ? ${wt.currentOutput} && wt.outputs.${wt.currentOutput}.path != null then
      wt.outputs.${wt.currentOutput}.path
    else
      "";
  settings = {
    lang = "en";
    cols = 6;
    rows = 4;
    background = "none";
    wallpaper = if wallpaperPath == "" then 0 else 1;
    wallpaper_file = wallpaperPath;
    wallpaper_mode = "cover";
    wallpaper_backend = "auto";
    child_lock = 0;
    tile_corner_radius = 12;
    tile_border_color = tokyonight.borderRgb;
    tile_mouse_hover_color = tokyonight.blueRgb;
    tile_keyboard_hover_color = tokyonight.yellowRgb;
    window_background_color = tokyonight.bgRgb;
    window_background_opacity = 0.85;
    tile_launch_animation = 1;
    tile_launch_animation_duration_ms = 300;
    tile_font_family = "Lilex Nerd Font";
    overlay_theme = {
      font_family = "Lilex Nerd Font";
      font_body_size = 15;
      font_title_size = 36;
      font_small_size = 13;
      font_mono_size = 15;
      panel_bg = "#1a1b26fa";
      panel_border = "#7aa2f79a";
      panel_top_light = "#7aa2f730";
      box_bg = "#16161dee";
      box_border = "#41486878";
      button_bg = "#292e42ec";
      button_border = "#7aa2f78c";
      accent = "#7aa2f7ee";
      text = "#c0caf5f8";
      title = "#c0caf5ff";
      muted = "#565f89e0";
      panel_padding = 28;
      panel_glow = 16;
      panel_border_width = 1;
      button_height = 36;
      scrollbar_width = 8;
      corner_radius = 12;
    };
    pages = [
      # Page 1 — apps. Mirrors the direct SUPER binds in hyprland.nix plus
      # the TUIs; commands run through sh -c, and hyprtile-shotter gets
      # --delay 3 so the fullscreen grid is gone before the capture.
      {
        tiles = [
          (tile "Terminal" "kitty" "icons/Development/terminal-fill.svg" "158,206,106")
          (tile "LibreWolf" "librewolf" "icons/Logos/firefox-fill.svg" "122,162,247")
          (tile "Brave" "brave" "icons/Logos/chrome-fill.svg" "255,158,100")
          (tile "Obsidian" "obsidian" "icons/Document/sticky-note-fill.svg" "187,154,247")
          (tile "Zed" "zeditor" "icons/Development/code-box-fill.svg" "125,207,255")
          (tile "Files" "nautilus" "icons/Document/folder-2-fill.svg" "224,175,104")
          (tile "Settings" "global-settings" "icons/System/settings-3-fill.svg" "192,202,245")
          (tile "Wallpapers" "kitty -e wallpaper-tui" "icons/Media/image-fill.svg" "115,218,202")
          (tile "Monitors" "kitty -e hyprmon" "icons/Device/computer-fill.svg" "42,195,222")
          (tile "Screenshot" "hyprtile-shotter --delay 3" "icons/Media/camera-fill.svg" "224,175,104")
          (tile "Recorder" "hyprtile-screener" "icons/Media/video-fill.svg" "247,118,142")
          (tile "Keybinds" "~/.config/eww/scripts/keybinds.sh --force" "icons/Design/edit-box-fill.svg"
            "187,154,247"
          )
          (tile "Sync apps" "hyprtile-sync-apps && notify-send HyprTile 'App pages refreshed'"
            "icons/System/apps-2-fill.svg"
            "158,206,106"
          )
        ];
      }
      # Page 2 — session/power. Replaces the rofi-power-menu grid
      # (SUPER+SHIFT+E). Logout via `hyprctl dispatch exit` ends the
      # compositor, which terminates the session like the old
      # loginctl-terminate-session powermenu entry did.
      {
        tiles = [
          (tile "Lock" "hyprlock" "icons/System/lock-fill.svg" "122,162,247")
          (tile "Logout" "hyprctl dispatch exit" "icons/System/logout-box-r-fill.svg" "192,202,245")
          (tile "Suspend" "systemctl suspend" "icons/Weather/moon-fill.svg" "125,207,255")
          (tile "Hibernate" "systemctl hibernate" "icons/Weather/moon-cloudy-fill.svg" "187,154,247")
          (tile "Reboot" "systemctl reboot" "icons/System/refresh-fill.svg" "158,206,106")
          (tile "Shutdown" "systemctl poweroff" "icons/Device/shut-down-fill.svg" "247,118,142")
        ];
      }
    ];
  };
  seedConfig = pkgs.writeText "hyprtile-config.json" (builtins.toJSON settings);

  # Auto-populate the launcher from everything installed: scans XDG .desktop
  # entries (system dirs first, $XDG_DATA_HOME last so user entries override
  # same-named ids; an override with NoDisplay=true removes the app),
  # resolves theme SVG icons out of MoreWaita/hicolor (find -L — NixOS icon
  # dirs are symlink forests), and regenerates pages 3+ of
  # ~/.hyprtile/config.json. Pages 1 (curated tiles) and 2 (power) are
  # never touched, which is what makes reruns idempotent. On PATH and on
  # the page-1 "Sync apps" tile.
  syncApps = pkgs.writeShellScriptBin "hyprtile-sync-apps" ''
    set -euo pipefail
    config="$HOME/.hyprtile/config.json"
    if [ ! -f "$config" ]; then
      echo "hyprtile-sync-apps: $config missing (home-manager seeds it on activation)" >&2
      exit 1
    fi
    jq=${pkgs.jq}/bin/jq

    IFS=: read -ra sys_dirs <<<"''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    data_dirs=("''${sys_dirs[@]}" "''${XDG_DATA_HOME:-$HOME/.local/share}")

    declare -A name_of exec_of icon_of term_of
    for d in "''${data_dirs[@]}"; do
      appdir="$d/applications"
      [ -d "$appdir" ] || continue
      while IFS= read -r f; do
        id="''${f#"$appdir/"}"
        line="$(awk -F= '
          { sub(/\r$/, "") }
          /^\[/ { in_e = ($0 == "[Desktop Entry]"); next }
          !in_e { next }
          $1 == "Type"      { type = $2 }
          $1 == "NoDisplay" { nod = $2 }
          $1 == "Hidden"    { hid = $2 }
          $1 == "Terminal"  { term = $2 }
          $1 == "Name" && name == "" { name = $0; sub(/^Name=/, "", name) }
          $1 == "Exec" && cmd == ""  { cmd = $0;  sub(/^Exec=/, "", cmd) }
          $1 == "Icon" && icon == "" { icon = $0; sub(/^Icon=/, "", icon) }
          END {
            if (type == "Application" && nod != "true" && hid != "true" && name != "" && cmd != "")
              printf "%s\037%s\037%s\037%s\n", name, cmd, icon, term
          }' "$f")"
        if [ -z "$line" ]; then
          unset "name_of[$id]" "exec_of[$id]" "icon_of[$id]" "term_of[$id]" 2>/dev/null || true
          continue
        fi
        IFS=$'\037' read -r n c i t <<<"$line"
        name_of[$id]=$n exec_of[$id]=$c icon_of[$id]=$i term_of[$id]=$t
      done < <(find -L "$appdir" -name '*.desktop' 2>/dev/null | sort)
    done

    resolve_icon() {
      local ic="$1" d theme found
      [ -n "$ic" ] || return 1
      case "$ic" in
        /*) [ -f "$ic" ] && printf '%s\n' "$ic" || return 1; return 0 ;;
      esac
      ic="''${ic%.svg}"; ic="''${ic%.png}"; ic="''${ic%.xpm}"
      for d in "''${data_dirs[@]}"; do
        for theme in MoreWaita hicolor; do
          found="$(find -L "$d/icons/$theme" -name "$ic.svg" -print -quit 2>/dev/null || true)"
          [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
        done
      done
      return 1
    }

    accents=("122,162,247" "158,206,106" "224,175,104" "187,154,247" \
             "125,207,255" "247,118,142" "255,158,100" "115,218,202")
    tiles_tmp="$(mktemp)"; trap 'rm -f "$tiles_tmp"' EXIT
    esc="$(printf '\001')"
    i=0
    while IFS= read -r id; do
      cmd="$(sed -e "s/%%/$esc/g" -e 's/ *%[fFuUdDnNickvm]//g' -e "s/$esc/%/g" \
        <<<"''${exec_of[$id]}")"
      [ "''${term_of[$id]:-false}" = "true" ] && cmd="kitty -e $cmd"
      icon="$(resolve_icon "''${icon_of[$id]:-}")" || icon="icons/System/apps-2-fill.svg"
      "$jq" -n --arg name "''${name_of[$id]}" --arg cmd "$cmd" --arg icon "$icon" \
        --arg col "''${accents[i % 8]}" \
        '{name:$name, command:$cmd, icon:$icon, icon_color:$col, bg:"#16161d", hov:"#292e42"}' \
        >>"$tiles_tmp"
      i=$((i + 1))
    done < <(printf '%s\n' "''${!name_of[@]}" | sort)

    per="$("$jq" -r '(.cols // 6) * (.rows // 4)' "$config")"
    tmp="$(mktemp)"
    "$jq" -s --argjson per "$per" '
      def chunk($n):
        if length == 0 then [] elif length <= $n then [.]
        else [.[0:$n]] + (.[$n:] | chunk($n)) end;
      .[0] as $cfg | (.[1] | sort_by(.name | ascii_downcase)) as $tiles |
      $cfg | .pages = (.pages[0:2] + ($tiles | chunk($per) | map({ tiles: . })))
    ' "$config" <("$jq" -s . "$tiles_tmp") >"$tmp" && mv "$tmp" "$config"
    echo "hyprtile-sync-apps: $i apps -> pages 3+ of $config"
  '';
in
{
  home.packages = [
    hyprtilePkg
    syncApps
  ];

  # Translations ship in the store; HyprTile only looks in
  # ~/.hyprtile/languages, so link that dir to the package share.
  home.file.".hyprtile/languages".source = "${hyprtilePkg}/share/hyprtile/languages";

  home.activation.seedHyprtileConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "$HOME/.hyprtile/config.json" ]; then
      run install -Dm644 ${seedConfig} "$HOME/.hyprtile/config.json"
    fi
  '';
}
