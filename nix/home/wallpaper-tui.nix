# swaybg-based TUI wallpaper changer — terminal replacement for waytrogen.
# Declarative Nix options own the settings; the inline Textual script (packaged
# via writers.writePython3Bin, same pattern as searxng-mcp in claude.nix) reads
# them and writes only runtime overrides.
#
# Two-file split (avoids waytrogen.nix's read-only-symlink workaround):
#   ~/.config/wallpaper-tui/config.json  — declarative, read-only, from Nix
#   ~/.local/state/wallpaper-tui/state.json — writable runtime picks, by the TUI
# Nix is the source of truth for folder/outputs/defaults; the TUI overrides per
# output for the session; --restore applies the effective merge. To make a pick
# permanent, declare it in Nix instead of relying on state.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.wallpaper-tui;
  modes = [
    "fill"
    "stretch"
    "fit"
    "center"
    "tile"
  ];

  wallpaper-tui =
    pkgs.writers.writePython3Bin "wallpaper-tui"
      {
        libraries = [ pkgs.python3Packages.textual ];
        flakeIgnore = [ "E501" ];
      }
      ''
        """swaybg-based TUI wallpaper changer (waytrogen replacement).

        Reads a declarative, read-only config (from Nix) for the wallpaper
        folder, recursive flag, current output and per-output defaults, and a
        writable state file for runtime overrides. --restore applies the
        effective merge of the two.
        """
        import argparse
        import json
        import os
        import subprocess
        import sys
        from pathlib import Path

        from textual.app import App, ComposeResult
        from textual.binding import Binding
        from textual.widgets import Footer, Header, Label, ListItem, ListView, Static

        CONFIG_FILE = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "wallpaper-tui" / "config.json"
        STATE_FILE = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "wallpaper-tui" / "state.json"
        EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
        MODES = ["fill", "stretch", "fit", "center", "tile"]
        # Tokyonight-adjacent palette for the `c` cycle (fill color for letterbox modes).
        COLOR_PALETTE = [
            "#d2a1a1", "#1a1b26", "#000000", "#ffffff",
            "#7aa2f7", "#bb9af7", "#9ece6a", "#f7768e",
        ]
        DEFAULT_COLOR = "#d2a1a1"


        def load_config():
            """Read the declarative (read-only) config from Nix."""
            try:
                return json.loads(CONFIG_FILE.read_text())
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                return {"wallpaper_folder": "", "recursive": True, "current_output": "", "outputs": {}}


        def load_state():
            """Read runtime override state (writable; may not exist yet)."""
            try:
                return json.loads(STATE_FILE.read_text())
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                return {"outputs": {}}


        def save_state(state):
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


        def list_wallpapers(folder, recursive):
            if not folder or not Path(folder).is_dir():
                return []
            it = Path(folder).rglob("*") if recursive else Path(folder).iterdir()
            paths = [p for p in it if p.is_file() and p.suffix.lower() in EXTENSIONS]
            # Newest first — matches waytrogen's sort_by: Date default.
            paths.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            return paths


        def detect_outputs():
            """Best-effort output enumeration via hyprctl; falls back to []."""
            if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
                return []
            try:
                out = subprocess.run(
                    ["hyprctl", "monitors", "-j"],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                return [m["name"] for m in json.loads(out.stdout)]
            except (subprocess.CalledProcessError, json.JSONDecodeError, OSError, KeyError):
                return []


        def effective_output(config, state, output):
            """Merge declarative defaults with runtime overrides for one output."""
            decl = config.get("outputs", {}).get(output, {})
            over = state.get("outputs", {}).get(output, {})
            return {
                "path": over.get("path") or decl.get("path") or "",
                "mode": over.get("mode") or decl.get("mode") or "fill",
                "fill_color": over.get("fill_color") or decl.get("fill_color") or DEFAULT_COLOR,
            }


        def apply_wallpaper(groups):
            """Kill any running swaybg and spawn a fresh instance applying `groups`.

            groups: list of dicts with keys: output, path, mode, fill_color.
            One swaybg process holds one -o group per entry, so multi-output
            restore is a single spawn. The child must be detached so it survives
            this process exiting (both the TUI and the --restore one-shot return
            immediately after launching). Returns the spawned Popen, or None if
            there was nothing to apply.
            """
            if not groups:
                return None
            # swaybg refuses to replace a running instance, so kill any first
            # (check=False tolerates "no such process"); mirrors random_wp.nix:48.
            subprocess.run(["pkill", "-u", os.environ.get("USER", ""), "-x", "swaybg"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # One flat command: a repeated -o/-i/-m/-c group per output entry.
            args = ["swaybg"]
            for g in groups:
                args += ["-o", g["output"], "-i", g["path"], "-m", g["mode"], "-c", g["fill_color"]]
            # start_new_session=True (setsid) + std streams to DEVNULL detaches
            # the child so it outlives this process (nohup-equivalent).
            return subprocess.Popen(args, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


        def restore_all(config, state):
            """Re-apply every declared output, using overrides where present."""
            groups = []
            for output in config.get("outputs", {}):
                eff = effective_output(config, state, output)
                if eff["path"] and Path(eff["path"]).exists():
                    groups.append({"output": output, **eff})
            if not groups:
                print("wallpaper-tui: nothing to restore.", file=sys.stderr)
                return 1
            apply_wallpaper(groups)
            print(f"wallpaper-tui: restored {len(groups)} output(s).", file=sys.stderr)
            return 0


        class WallpaperTUI(App):
            """Textual picker: browse wallpapers, tune mode/color/output, apply."""

            BINDINGS = [
                Binding("j", "cursor_down", "Down", show=False),
                Binding("k", "cursor_up", "Up", show=False),
                Binding("enter", "apply", "Apply"),
                Binding("m", "cycle_mode", "Mode"),
                Binding("c", "set_color", "Color"),
                Binding("o", "cycle_output", "Output"),
                Binding("r", "restore", "Restore"),
                Binding("q", "quit", "Quit"),
            ]

            def __init__(self, config, state):
                super().__init__()
                self.config = config
                self.state = state
                self.outputs = detect_outputs()
                for name in self.config.get("outputs", {}):
                    if name not in self.outputs:
                        self.outputs.append(name)
                if not self.outputs:
                    self.outputs = ["*"]
                cur = self.config.get("current_output", "") or ""
                if cur not in self.outputs:
                    cur = self.outputs[0]
                self.current_output = cur
                eff = effective_output(self.config, self.state, self.current_output)
                self.fill_mode = eff["mode"]
                self.current_color = eff["fill_color"]
                self.wallpapers = list_wallpapers(
                    self.config.get("wallpaper_folder", ""),
                    self.config.get("recursive", True),
                )

            def output_state(self):
                return self.state.setdefault("outputs", {}).setdefault(self.current_output, {})

            def compose(self) -> ComposeResult:
                yield Header()
                if self.wallpapers:
                    yield ListView(
                        *[ListItem(Label(p.name), name=str(p)) for p in self.wallpapers],
                        id="list",
                    )
                else:
                    yield Label(
                        f"No wallpapers found in: {self.config.get('wallpaper_folder', '?')}",
                        id="empty",
                    )
                yield Static(self.info_text(), id="info")
                yield Footer()

            def info_text(self):
                eff = effective_output(self.config, self.state, self.current_output)
                path = eff["path"]
                name = Path(path).name if path else "(none)"
                return (
                    f" Output: {self.current_output} | Mode: {self.fill_mode} "
                    f"| Color: {self.current_color} | Current: {name} "
                )

            def refresh_info(self):
                self.query_one("#info", Static).update(self.info_text())

            def selected_path(self):
                try:
                    lv = self.query_one("#list", ListView)
                except Exception:
                    return None
                child = lv.highlighted_child
                return child.name if child is not None else None

            def on_list_view_selected(self, event):
                # Enter/click on a list row → apply it to the current output.
                self.action_apply()

            def action_cursor_up(self):
                lv = self.query_one("#list", ListView)
                if lv.highlighted is None:
                    lv.highlighted = len(lv.children) - 1
                elif lv.highlighted > 0:
                    lv.highlighted -= 1

            def action_cursor_down(self):
                lv = self.query_one("#list", ListView)
                if lv.highlighted is None:
                    lv.highlighted = 0
                elif lv.highlighted < len(lv.children) - 1:
                    lv.highlighted += 1

            def action_cycle_mode(self):
                idx = MODES.index(self.fill_mode) if self.fill_mode in MODES else 0
                self.fill_mode = MODES[(idx + 1) % len(MODES)]
                self.refresh_info()

            def action_cycle_output(self):
                idx = self.outputs.index(self.current_output) if self.current_output in self.outputs else 0
                self.current_output = self.outputs[(idx + 1) % len(self.outputs)]
                eff = effective_output(self.config, self.state, self.current_output)
                self.fill_mode = eff["mode"]
                self.current_color = eff["fill_color"]
                self.refresh_info()

            def action_set_color(self):
                idx = COLOR_PALETTE.index(self.current_color) if self.current_color in COLOR_PALETTE else -1
                self.current_color = COLOR_PALETTE[(idx + 1) % len(COLOR_PALETTE)]
                self.refresh_info()

            def action_apply(self):
                path = self.selected_path()
                if not path:
                    return
                st = self.output_state()
                st["path"] = path
                st["mode"] = self.fill_mode
                st["fill_color"] = self.current_color
                save_state(self.state)
                apply_wallpaper([{
                    "output": self.current_output,
                    "path": path,
                    "mode": self.fill_mode,
                    "fill_color": self.current_color,
                }])
                self.refresh_info()

            def action_restore(self):
                restore_all(self.config, self.state)

            def action_quit(self):
                self.exit()


        def main():
            parser = argparse.ArgumentParser(description="swaybg-based TUI wallpaper changer")
            parser.add_argument("--restore", action="store_true", help="re-apply effective wallpapers and exit")
            parser.add_argument("--output", help="output name (non-interactive apply)")
            parser.add_argument("--mode", choices=MODES, default="fill")
            parser.add_argument("--color", default=DEFAULT_COLOR)
            parser.add_argument("path", nargs="?", help="wallpaper path (non-interactive apply)")
            args = parser.parse_args()

            config = load_config()
            state = load_state()

            if args.restore:
                sys.exit(restore_all(config, state))

            if args.path:
                if not args.output:
                    parser.error("--output is required when a path is given")
                state.setdefault("outputs", {})[args.output] = {
                    "path": args.path,
                    "mode": args.mode,
                    "fill_color": args.color,
                }
                save_state(state)
                apply_wallpaper([{
                    "output": args.output,
                    "path": args.path,
                    "mode": args.mode,
                    "fill_color": args.color,
                }])
                print(f"wallpaper-tui: applied {args.path} to {args.output}.", file=sys.stderr)
                return

            app = WallpaperTUI(config, state)
            app.run()


        if __name__ == "__main__":
            main()
      '';

  declarativeConfig = builtins.toJSON {
    wallpaper_folder = cfg.wallpaperFolder;
    recursive = cfg.recursive;
    current_output = cfg.currentOutput;
    outputs = lib.mapAttrs (_: o: {
      path = o.path;
      mode = o.mode;
      fill_color = o.fillColor;
    }) cfg.outputs;
  };
in
{
  options.programs.wallpaper-tui = {
    enable = lib.mkEnableOption "swaybg-based TUI wallpaper changer";

    wallpaperFolder = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Dokumente/codeberg/personal/dots/Wallpapers/wh";
      description = "Folder scanned for wallpapers.";
    };

    recursive = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to descend into subdirectories of wallpaperFolder.";
    };

    currentOutput = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Output focused by default in the TUI.";
    };

    outputs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default wallpaper path for this output (null = none).";
          };
          mode = lib.mkOption {
            type = lib.types.enum modes;
            default = "fill";
            description = "swaybg scaling mode.";
          };
          fillColor = lib.mkOption {
            type = lib.types.str;
            default = "#d2a1a1";
            description = "Fill color (hex) for letterbox modes.";
          };
        };
      });
      default = { };
      description = "Per-output declarative wallpaper defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."wallpaper-tui/config.json".text = declarativeConfig;
    home.packages = [ wallpaper-tui ];
  };
}