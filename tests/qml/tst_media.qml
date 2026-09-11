// Media pill: which player it speaks for, and what it draws for that
// player.
//
// Everything under "logic" runs over plain objects standing in for
// MprisPlayer, with no D-Bus and no player actually running, for the reason
// battery.js and focusedwindow.js give in tests/README.md: Media.qml itself
// binds Quickshell.Services.Mpris, which qmltestrunner cannot instantiate.
//
// "wiring" reads Media.qml as text, the idiom tst_focusedwindow_wiring.qml
// and tst_idle.qml's own final section use for the same reason: a correct
// activePlayer() proves nothing about whether the component actually calls
// it, or calls the right MPRIS method from the right button.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/media/media.js" as Media
import "sourcescan.js" as Scan

TestCase {
    name: "Media"

    // ---- activePlayer ----

    function test_activePlayer_prefers_whichever_player_is_actually_playing() {
        const paused = { isPlaying: false, trackTitle: "Paused One" };
        const playing = { isPlaying: true, trackTitle: "Playing One" };

        compare(Media.activePlayer([paused, playing]), playing, "a playing player must win over a paused one regardless of order");
        compare(Media.activePlayer([playing, paused]), playing, "and regardless of the other order too");
    }

    function test_activePlayer_falls_back_to_the_first_player_when_none_are_playing() {
        const first = { isPlaying: false, trackTitle: "First" };
        const second = { isPlaying: false, trackTitle: "Second" };

        compare(Media.activePlayer([first, second]), first, "a paused resume target beats no pill at all");
    }

    function test_activePlayer_is_null_with_no_players_data() {
        return [
            { tag: "empty array", players: [] },
            { tag: "undefined", players: undefined },
            { tag: "null", players: null }
        ];
    }

    function test_activePlayer_is_null_with_no_players(row) {
        compare(Media.activePlayer(row.players), null, row.tag);
    }

    // ---- label ----

    function test_label_joins_title_and_artist_with_an_em_dash() {
        compare(Media.label("Origin", "Elgato"), "Origin — Elgato");
    }

    function test_label_falls_back_to_whichever_half_is_known_data() {
        return [
            { tag: "title only", title: "Origin", artist: "", expected: "Origin" },
            { tag: "artist only", title: "", artist: "Elgato", expected: "Elgato" },
            { tag: "title only, artist undefined", title: "Origin", artist: undefined, expected: "Origin" }
        ];
    }

    function test_label_falls_back_to_whichever_half_is_known(row) {
        compare(Media.label(row.title, row.artist), row.expected, row.tag);
    }

    // A player MPRIS has announced but not yet sent metadata for is a real,
    // observable gap, not a hypothetical: the pill must say something other
    // than a bare " — " while it waits.
    function test_label_names_a_player_with_no_metadata_yet_data() {
        return [
            { tag: "both empty", title: "", artist: "" },
            { tag: "both undefined", title: undefined, artist: undefined }
        ];
    }

    function test_label_names_a_player_with_no_metadata_yet(row) {
        compare(Media.label(row.title, row.artist), "No track", row.tag);
    }

    // ---- playPauseGlyph ----

    function test_playPauseGlyph_shows_the_action_a_click_will_take_next() {
        compare(Media.playPauseGlyph(true), Media.GLYPH_PAUSE, "a playing player's click pauses it");
        compare(Media.playPauseGlyph(false), Media.GLYPH_PLAY, "a paused player's click plays it");
        verify(Media.GLYPH_PAUSE !== Media.GLYPH_PLAY, "the two states must render as visibly different glyphs");
    }

    // ---- wiring ----

    function mediaSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../nix/home/desktop/quickshell/qml/media/Media.qml"), false);
        xhr.send();
        compare(xhr.status, 200, "Media.qml must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function test_the_pill_hides_with_no_active_player() {
        const src = mediaSource();

        const rootStart = src.indexOf("Pill {");
        const visibleAt = src.indexOf("visible: root.player !== null");
        const firstChildAt = src.indexOf("Text {");

        verify(rootStart !== -1 && visibleAt !== -1 && firstChildAt !== -1, "all three anchors must be found");
        verify(visibleAt > rootStart && visibleAt < firstChildAt, "visible must be bound on the Pill root, before its first child");
    }

    // Tray.qml's own reason applies here too: `interactive` enables one
    // MouseArea over the whole capsule, which would swallow a click meant
    // for one specific button before the button's own MouseArea saw it.
    function test_the_pill_does_not_enable_its_own_whole_capsule_click_handler() {
        verify(mediaSource().indexOf("interactive") === -1, "per-button MouseAreas need Pill.interactive to stay at its false default");
    }

    function test_each_control_calls_its_own_mpris_method_data() {
        return [
            { tag: "previous", call: "root.player?.previous()" },
            { tag: "play/pause", call: "root.player?.togglePlaying()" },
            { tag: "next", call: "root.player?.next()" }
        ];
    }

    function test_each_control_calls_its_own_mpris_method(row) {
        verify(mediaSource().indexOf(row.call) !== -1, `must call ${row.call}`);
    }
}
