// The sidebar's XDG places, driven with captured user-dirs.dirs contents
// and no filesystem.
//
// The localised names are the whole reason this is parsed rather than
// hardcoded: on this login Desktop is "Schreibtisch" and Public is
// "Öffentlich", so an English literal would point at directories that do
// not exist.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/files/places.js" as Places

TestCase {
    name: "FilesPlaces"

    property string home: "/home/matus"

    property string sample: '# xdg-user-dirs generated\n' + 'XDG_DESKTOP_DIR="$HOME/Schreibtisch"\n' + 'XDG_DOWNLOAD_DIR="$HOME/Downloads"\n' + 'XDG_DOCUMENTS_DIR="$HOME/Dokumente"\n' + 'XDG_MUSIC_DIR="$HOME/Musik"\n' + 'XDG_PICTURES_DIR="$HOME/Bilder"\n' + 'XDG_VIDEOS_DIR="$HOME/Videos"\n' + 'XDG_PUBLICSHARE_DIR="$HOME/Öffentlich"\n' + 'XDG_TEMPLATES_DIR="$HOME/Vorlagen"\n'

    function labels(places) {
        return places.map(place => place.label);
    }

    function paths(places) {
        return places.map(place => place.path);
    }

    function test_home_is_expanded_from_the_literal_dollar_home() {
        const dirs = Places.parseUserDirs(sample, home);

        compare(dirs.XDG_MUSIC_DIR, "/home/matus/Musik");
    }

    function test_the_localised_name_survives_verbatim() {
        const dirs = Places.parseUserDirs(sample, home);

        compare(dirs.XDG_DESKTOP_DIR, "/home/matus/Schreibtisch");
        compare(dirs.XDG_PUBLICSHARE_DIR, "/home/matus/Öffentlich");
    }

    function test_comments_and_blank_lines_are_skipped() {
        const dirs = Places.parseUserDirs("# a comment\n\nXDG_MUSIC_DIR=\"$HOME/M\"\n", home);

        compare(Object.keys(dirs).length, 1);
    }

    // xdg-user-dirs writes the key back pointing at $HOME to mean the
    // directory is disabled. Home already has its own row, so a second one
    // labelled Music would just be a duplicate.
    function test_a_directory_pointing_at_home_itself_is_treated_as_disabled() {
        const dirs = Places.parseUserDirs('XDG_MUSIC_DIR="$HOME"\n', home);

        compare(Object.keys(dirs).length, 0);
    }

    function test_an_absolute_path_is_kept_as_written() {
        const dirs = Places.parseUserDirs('XDG_MUSIC_DIR="/mnt/media/music"\n', home);

        compare(dirs.XDG_MUSIC_DIR, "/mnt/media/music");
    }

    function test_home_always_leads_the_list() {
        const places = Places.placesFor(sample, home);

        compare(places[0].label, "Home");
        compare(places[0].path, home);
    }

    // The order is the sidebar's, not the file's, so it does not reshuffle
    // when xdg-user-dirs rewrites user-dirs.dirs in a different order.
    function test_the_order_is_the_modules_own_not_the_files() {
        compare(labels(Places.placesFor(sample, home)), ["Home", "Documents", "Downloads", "Pictures", "Music", "Videos", "Desktop", "Public", "Templates"]);
    }

    // A user who deleted or never had a directory should not get a sidebar
    // row leading nowhere.
    function test_a_missing_key_is_skipped_rather_than_guessed() {
        const places = Places.placesFor('XDG_MUSIC_DIR="$HOME/Musik"\n', home);

        compare(labels(places), ["Home", "Music"]);
    }

    // No user-dirs.dirs at all is a normal login, not an error.
    function test_an_empty_file_still_yields_home() {
        compare(labels(Places.placesFor("", home)), ["Home"]);
    }

    function test_every_place_carries_a_glyph_and_a_real_palette_token() {
        const known = ["accent", "fg", "blue", "cyan", "green", "magenta", "red", "yellow", "orange", "dim"];

        for (const place of Places.placesFor(sample, home)) {
            verify(place.glyph.length > 0, `${place.label} has no glyph`);
            verify(known.indexOf(place.colour) >= 0, `${place.label} uses an unknown token`);
        }
    }

    function test_every_place_resolves_to_an_absolute_path() {
        for (const path of paths(Places.placesFor(sample, home)))
            verify(path.startsWith("/"), `${path} is not absolute`);
    }

    // The bookmarks half. Same file GTK writes, so these are the shapes it
    // actually produces rather than ones invented here.
    function test_a_bare_file_uri_takes_its_basename_as_the_label() {
        const marks = Places.parseBookmarks("file:///home/matus/Dokumente/gitlab\n");

        compare(marks.length, 1);
        compare(marks[0].path, "/home/matus/Dokumente/gitlab");
        compare(marks[0].label, "gitlab");
    }

    // GTK puts a display label after a space when the user renames a
    // bookmark, and that name wins over the basename.
    function test_an_explicit_label_wins_over_the_basename() {
        const marks = Places.parseBookmarks("file:///home/matus/Dokumente/gitlab Work Repos\n");

        compare(marks[0].path, "/home/matus/Dokumente/gitlab");
        compare(marks[0].label, "Work Repos");
    }

    function test_a_percent_escape_is_decoded_into_a_real_path() {
        const marks = Places.parseBookmarks("file:///home/matus/My%20Docs\n");

        compare(marks[0].path, "/home/matus/My Docs");
        compare(marks[0].label, "My Docs");
    }

    // A stray percent is not a valid escape and makes decodeURIComponent
    // throw. The bookmark degrades to its raw text rather than taking the
    // whole list down with it.
    function test_a_malformed_escape_keeps_the_raw_path() {
        const marks = Places.parseBookmarks("file:///home/matus/100%done\n");

        compare(marks.length, 1);
        compare(marks[0].path, "/home/matus/100%done");
    }

    // GTK stores smb:// and sftp:// in the same file, and the pane lists
    // with `find`, which cannot reach either.
    function test_a_non_file_scheme_is_skipped() {
        const marks = Places.parseBookmarks("smb://server/share\nfile:///home/matus/ok\nsftp://host/x\n");

        compare(marks.length, 1);
        compare(marks[0].path, "/home/matus/ok");
    }

    function test_blank_lines_and_junk_are_skipped() {
        compare(Places.parseBookmarks("\n   \nnot-a-uri\n").length, 0);
    }

    function test_every_bookmark_carries_a_glyph_and_a_real_palette_token() {
        const known = ["accent", "fg", "blue", "cyan", "green", "magenta", "red", "yellow", "orange", "dim"];

        for (const mark of Places.parseBookmarks("file:///home/matus/a\nfile:///home/matus/b\n")) {
            verify(mark.glyph.length > 0);
            verify(known.indexOf(mark.colour) >= 0);
        }
    }
}
