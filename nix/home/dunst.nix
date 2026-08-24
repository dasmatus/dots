# services.dunst port of files/dunst/dunstrc (deleted — see git history).
# Deliberate deviations: dmenu/browser no longer hardcode /usr/bin (NixOS
# has no FHS there) — dmenu now shells to the rofi module below, browser to
# xdg-open; icon_theme switched from Papirus-Dark to morewaita to match the
# gtk.iconTheme set in default.nix.
{ ... }:
{
  services.dunst = {
    enable = true;

    settings = {
      global = {
        monitor = 0;
        follow = "mouse";

        width = 300;
        height = 300;
        origin = "top-right";
        offset = "12x48";
        scale = 0;

        notification_limit = 5;

        progress_bar = true;
        progress_bar_height = 6;
        progress_bar_frame_width = 1;
        progress_bar_min_width = 150;
        progress_bar_max_width = 300;
        progress_bar_corner_radius = 3;

        indicate_hidden = true;
        transparency = 10;
        separator_height = 2;
        padding = 10;
        horizontal_padding = 12;
        text_icon_padding = 0;
        frame_width = 2;
        frame_color = "#414868";
        gap_size = 6;
        separator_color = "frame";
        sort = true;

        font = "Lilex Nerd Font Bold 10";
        line_height = 0;
        markup = "full";
        format = "<b>%s</b>\\n%b";
        alignment = "left";
        vertical_alignment = "center";
        show_age_threshold = 60;
        ellipsize = "middle";
        ignore_newline = false;
        stack_duplicates = true;
        hide_duplicate_count = false;
        show_indicators = true;

        enable_recursive_icon_lookup = true;
        # "MoreWaita", not "morewaita". dunst matches this against the theme's
        # directory name, which is capitalised; with the lowercase spelling it
        # logs `WARNING: Could not find theme morewaita` and loads no theme at
        # all.
        #
        # Worth knowing before trusting it: fixing the case makes the theme load
        # and does *not* by itself make icons appear. Measured against dunst
        # 1.13.2 on a throwaway bus, no icon passed by name resolves under this
        # dunstrc. Not an Adwaita symbolic name, not a PNG-backed legacy name,
        # not one MoreWaita ships itself, under any theme spelling. Only icons
        # passed as a file path (hyprshot's screenshots) render today. That is a
        # separate fault and was not tracked down; this line only removes the
        # one cause that could be pinned on the configuration.
        icon_theme = "MoreWaita";
        icon_position = "left";
        min_icon_size = 0;
        max_icon_size = 32;

        sticky_history = true;
        history_length = 20;

        dmenu = "rofi -dmenu -p dunst";
        browser = "xdg-open";

        always_run_script = true;
        title = "Dunst";
        class = "Dunst";

        corner_radius = 8;

        ignore_dbusclose = false;

        force_xwayland = false;
        force_xinerama = false;

        mouse_left_click = "close_current";
        mouse_middle_click = "do_action, close_current";
        mouse_right_click = "close_all";
      };

      urgency_low = {
        background = "#1a1b26";
        foreground = "#c0caf5";
        frame_color = "#414868";
        timeout = 5;
      };

      urgency_normal = {
        background = "#1f2335";
        foreground = "#c0caf5";
        frame_color = "#7aa2f7";
        timeout = 8;
      };

      urgency_critical = {
        background = "#1f2335";
        foreground = "#f7768e";
        frame_color = "#f7768e";
        timeout = 0;
      };
    };
  };
}
