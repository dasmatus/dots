// Pure logic behind Media.qml: which player is "the" player, and what its
// pill draws.
//
// Split out for the reason tests/README.md gives for battery.js and
// focusedwindow.js: Media.qml itself binds Quickshell.Services.Mpris, which
// qmltestrunner cannot instantiate. Everything here runs over plain
// objects and strings, so a test can stand a fake MprisPlayer up with no
// D-Bus and no player actually running.
.pragma library

// FontAwesome's own codepoints, the same set nix/home/desktop/quickshell's
// other pills already draw from (Network.qml's wifi/wired glyphs, Osd.qml's
// volume ramp). Kept as named constants here, unlike those two, because
// playPauseGlyph below has to choose between two of them.
var GLYPH_MUSIC = "\u{F001}";
var GLYPH_PREVIOUS = "\u{F048}";
var GLYPH_PLAY = "\u{F04B}";
var GLYPH_PAUSE = "\u{F04C}";
var GLYPH_NEXT = "\u{F051}";

// Shown in place of a track title/artist for a player MPRIS has announced
// but not yet sent metadata for — the gap between a player appearing on the
// bus and its first PropertiesChanged, which is real and observable, not a
// hypothetical.
var NO_TRACK = "No track";

// Which of possibly several MPRIS players the pill speaks for. A machine
// with a browser tab, a terminal music client and a chat app's ringtone
// player can have all three on the bus at once; the one actually making
// sound is the one worth a bar capsule, so a playing player always wins
// over a paused or stopped one regardless of arrival order. Falling back to
// the first player when none are playing keeps a paused "resume" pill
// available instead of the bar going silent about music that merely isn't
// moving right now.
function activePlayer(players) {
    if (!players || players.length === 0)
        return null;

    for (const player of players) {
        if (player && player.isPlaying)
            return player;
    }

    return players[0] ?? null;
}

// Title and artist, joined the way a tracklist would: an em dash between
// them when both are known, whichever one is known alone when only one is,
// and NO_TRACK when MPRIS has announced the player but not its metadata yet.
function label(title, artist) {
    var hasTitle = !!title;
    var hasArtist = !!artist;

    if (hasTitle && hasArtist)
        return `${title} — ${artist}`;

    if (hasTitle)
        return title;

    if (hasArtist)
        return artist;

    return NO_TRACK;
}

// The one glyph that changes meaning rather than merely appearing or not:
// every other control glyph (previous/next) is shown or hidden by the
// player's own canGoNext/canGoPrevious, but play/pause is always shown and
// has to say which action a click will take next.
function playPauseGlyph(isPlaying) {
    return isPlaying ? GLYPH_PAUSE : GLYPH_PLAY;
}
