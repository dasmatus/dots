#!/usr/bin/env bash
# Generate README screenshots for tokyonight-dots.
#
# Stage 1: capture the installer TUI (welcome + disk picker) in a sized,
#           Tokyonight-themed alacritty window.
# Stage 2: capture the wallpaper-tui selector once rust/wallpaper-tui/src/main.rs
#           exists and builds.
#
# Safety: this script refuses to run unless DOTS_INSTALLER_DRY_RUN=1 is exported
# in the environment; the installer binary honours it and never touches disks.
#
# Run from the repo root:
#   DOTS_INSTALLER_DRY_RUN=1 ./scripts/screenshot-readme.sh
#
# The script will re-exec itself inside a transient nix shell that supplies
# wtype, grim and jq if they are not already on PATH.
set -euo pipefail

# Re-exec inside a nix shell when missing tools.
if ! { command -v wtype >/dev/null 2>&1 && command -v grim >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }; then
    echo "[screenshot] tools missing; entering nix shell for wtype/grim/jq..."
    exec nix shell nixpkgs#wtype nixpkgs#grim nixpkgs#jq -c "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOT_DIR="$REPO_ROOT/docs/screenshots"
README="$REPO_ROOT/README.md"

WINDOW_CLASS="screenshot-installer"
WINDOW_TITLE="Dots Installer"
INSTALLER_WELCOME="$SHOT_DIR/installer-welcome.png"
INSTALLER_DISK="$SHOT_DIR/installer-disk.png"
WALLPAPER_TUI_SHOT="$SHOT_DIR/wallpaper-tui.png"

# ── Safety gate ───────────────────────────────────────────────────────────────
if [[ "${DOTS_INSTALLER_DRY_RUN:-}" != "1" ]]; then
    cat >&2 <<'EOF'
error: DOTS_INSTALLER_DRY_RUN=1 is required.

The installer TUI is a disk-formatting tool. This script only screenshots it,
but the binary itself will refuse to start unless you explicitly opt into the
dry-run mode so no real disk operations can happen.

Run:
    DOTS_INSTALLER_DRY_RUN=1 ./scripts/screenshot-readme.sh
EOF
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
info() { echo "[screenshot] $*"; }

wait_for_window() {
    local attempts=50
    while (( attempts-- > 0 )); do
        if hyprctl clients -j 2>/dev/null | jq -e --arg cls "$WINDOW_CLASS" '.[] | select(.class == $cls or .initialClass == $cls)' >/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    echo "error: window with class '$WINDOW_CLASS' did not appear" >&2
    return 1
}

window_geometry_by_class() {
    local cls="$1"
    hyprctl clients -j 2>/dev/null | jq -r --arg cls "$cls" '
        [ .[] | select(.class == $cls or .initialClass == $cls) | limit(1; .) ]
        | first
        | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"
    ' | tr -d '[:space:]'
}

capture_window() {
    local out="$1"
    local cls="$2"
    local geom
    geom="$(window_geometry_by_class "$cls")"
    if [[ -z "$geom" ]]; then
        echo "error: could not determine geometry for class '$cls'" >&2
        return 1
    fi
    mkdir -p "$(dirname "$out")"
    grim -g "$geom" "$out"
    info "captured $out ($geom)"
}

focus_window() {
    hyprctl dispatch "hl.dsp.focus({ window = \"class:${WINDOW_CLASS}\" })" >/dev/null 2>&1 || true
}

float_window() {
    hyprctl dispatch "hl.dsp.window.float({ action = \"set\", window = \"class:${WINDOW_CLASS}\" })" >/dev/null 2>&1 || true
}

send_key() {
    focus_window
    sleep 0.2
    wtype "$@"
    sleep 0.3
}

send_literal() {
    focus_window
    sleep 0.2
    wtype "$1"
    sleep 0.3
}

update_readme_screenshots_section() {
    if [[ ! -f "$README" ]]; then
        info "README not found; skipping link update"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN

    # Drop any existing "## Screenshots" section (from the heading to the next
    # "## " heading or EOF) and then append a freshly generated one.
    awk '
        /^## Screenshots$/ { skip = 1; next }
        skip && /^## / { skip = 0 }
        !skip { print }
    ' "$README" > "$tmp"

    {
        echo ""
        echo "## Screenshots"
        echo ""
        echo "<!-- screenshot:installer-welcome -->"
        echo "![Installer welcome screen](./docs/screenshots/installer-welcome.png)"
        echo ""
        echo "<!-- screenshot:installer-disk -->"
        echo "![Installer disk selection](./docs/screenshots/installer-disk.png)"
        if [[ -f "$WALLPAPER_TUI_SHOT" ]]; then
            echo ""
            echo "<!-- screenshot:wallpaper-tui -->"
            echo "![Wallpaper TUI](./docs/screenshots/wallpaper-tui.png)"
        fi
    } >> "$tmp"

    mv "$tmp" "$README"
    info "updated $README Screenshots section"
}

# ── Stage 1: installer-tui screenshots ──────────────────────────────────────────
info "starting installer TUI screenshots"
mkdir -p "$SHOT_DIR"

# Kill any leftover screenshot window.
for p in $(hyprctl clients -j 2>/dev/null | jq -r --arg cls "$WINDOW_CLASS" '.[] | select(.class == $cls or .initialClass == $cls) | .pid'); do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
done
sleep 0.5

# Launch alacritty with a fixed, roomy terminal and a dark Tokyonight background.
alacritty \
    --class "$WINDOW_CLASS" \
    --title "$WINDOW_TITLE" \
    -o "window.dimensions.columns=120" \
    -o "window.dimensions.lines=34" \
    -o "window.position.x=200" \
    -o "window.position.y=120" \
    -o "window.padding.x=20" \
    -o "window.padding.y=20" \
    -o "colors.primary.background=\"#1a1b26\"" \
    -o "colors.primary.foreground=\"#c0caf5\"" \
    -o "font.size=12.0" \
    -e bash -c "cd '$REPO_ROOT'; DOTS_INSTALLER_DRY_RUN=1 nix run .#dots-installer" \
    >/dev/null 2>&1 &

INSTALLER_PID=$!
info "installer terminal launched (pid $INSTALLER_PID)"

# Wait for the window to appear and make it floating + focused.
wait_for_window
float_window
focus_window
sleep 1.0

# Welcome screen.
capture_window "$INSTALLER_WELCOME" "$WINDOW_CLASS"

# Advance to network, then immediately skip to disk selection.
send_key -k Return
send_literal "s"
sleep 0.8

# Disk selection screen.
capture_window "$INSTALLER_DISK" "$WINDOW_CLASS"

# Quit the installer.
send_key -k Esc
sleep 0.5

# Ensure the terminal is gone.
kill "$INSTALLER_PID" 2>/dev/null || true
wait "$INSTALLER_PID" 2>/dev/null || true

# ── Stage 2: wallpaper-tui screenshot (gated) ─────────────────────────────────
if [[ -f "$REPO_ROOT/rust/wallpaper-tui/src/main.rs" ]]; then
    info "wallpaper-tui main.rs found; attempting to build and screenshot"
    if (cd "$REPO_ROOT/rust/wallpaper-tui" && cargo build --release 2>/dev/null); then
        WALLPAPER_TUI_CLASS="screenshot-wallpaper-tui"
        WALLPAPER_TUI_TITLE="Wallpaper TUI"

        for p in $(hyprctl clients -j 2>/dev/null | jq -r --arg cls "$WALLPAPER_TUI_CLASS" '.[] | select(.class == $cls or .initialClass == $cls) | .pid'); do
            [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
        done
        sleep 0.5

        alacritty \
            --class "$WALLPAPER_TUI_CLASS" \
            --title "$WALLPAPER_TUI_TITLE" \
            -o "window.dimensions.columns=140" \
            -o "window.dimensions.lines=40" \
            -o "window.position.x=150" \
            -o "window.position.y=100" \
            -o "window.padding.x=16" \
            -o "window.padding.y=16" \
            -o "colors.primary.background=\"#1a1b26\"" \
            -o "colors.primary.foreground=\"#c0caf5\"" \
            -o "font.size=11.0" \
            -e bash -c "cd '$REPO_ROOT/rust/wallpaper-tui'; ./target/release/wallpaper-tui '$REPO_ROOT/Wallpapers/night'" \
            >/dev/null 2>&1 &

        WALLPAPER_PID=$!
        sleep 1

        if hyprctl clients -j 2>/dev/null | jq -e --arg cls "$WALLPAPER_TUI_CLASS" '.[] | select(.class == $cls or .initialClass == $cls)' >/dev/null; then
            WINDOW_CLASS="$WALLPAPER_TUI_CLASS"
            float_window
            focus_window
            sleep 1.0
            capture_window "$WALLPAPER_TUI_SHOT" "$WINDOW_CLASS"
            send_key -k q
            sleep 0.3
        else
            info "wallpaper-tui window did not appear; skipping"
        fi

        kill "$WALLPAPER_PID" 2>/dev/null || true
        wait "$WALLPAPER_PID" 2>/dev/null || true
    else
        info "wallpaper-tui build failed; skipping stage 2"
    fi
else
    info "rust/wallpaper-tui/src/main.rs not found; skipping stage 2"
fi

# ── Stage 3: update README links ──────────────────────────────────────────────
if [[ -f "$README" ]]; then
    info "updating README links"
    update_readme_link "installer-welcome.png" "<!-- screenshot:installer-welcome -->" "Installer welcome screen" "installer-welcome.png"
    update_readme_link "installer-disk.png" "<!-- screenshot:installer-disk -->" "Installer disk selection" "installer-disk.png"
    if [[ -f "$WALLPAPER_TUI_SHOT" ]]; then
        update_readme_link "wallpaper-tui.png" "<!-- screenshot:wallpaper-tui -->" "Wallpaper TUI" "wallpaper-tui.png"
    fi
fi

info "done. Generated files:"
ls -lh "$INSTALLER_WELCOME" "$INSTALLER_DISK" 2>/dev/null || true
[[ -f "$WALLPAPER_TUI_SHOT" ]] && ls -lh "$WALLPAPER_TUI_SHOT"
