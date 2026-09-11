// File-type glyphs and their colours, keyed on the extension.
//
// Returns a token NAME ("blue", "orange") rather than a colour, exactly as
// BatteryMath.colorName() does for bar/Battery.qml: this file stays pure
// JS a test can drive, and the caller does the one `Theme` lookup. Putting
// a real colour here would mean importing Theme into a `.pragma library`,
// which is the hex-literal-in-QML problem wearing a different hat.
//
// Codepoints are Nerd Font, written as `\u{...}` escapes the way
// bar/Battery.qml writes its battery ramp. Every one below was checked against
// the installed Lilex Nerd Font with `fc-list ":charset=<cp>:family=Lilex Nerd
// Font"` before being added. An unmapped codepoint renders as a tofu box,
// which no test can see and qmllint does not know about.
.pragma library

var FOLDER = "\u{F024B}";
var FILE = "\u{F0214}";

// One entry per extension. Grouped by what the glyph is, not
// alphabetically, so adding a sibling extension lands next to its family.
var BY_EXTENSION = {
    nix: { glyph: "\u{F1105}", colour: "blue" },

    json: { glyph: "\u{E60B}", colour: "blue" },
    toml: { glyph: "\u{E796}", colour: "blue" },
    yaml: { glyph: "\u{E796}", colour: "blue" },
    yml: { glyph: "\u{E796}", colour: "blue" },
    ini: { glyph: "\u{E796}", colour: "blue" },
    conf: { glyph: "\u{E796}", colour: "blue" },
    cfg: { glyph: "\u{E796}", colour: "blue" },
    lock: { glyph: "\u{E796}", colour: "dim" },

    rs: { glyph: "\u{E7A8}", colour: "orange" },
    py: { glyph: "\u{E73C}", colour: "yellow" },
    js: { glyph: "\u{E718}", colour: "yellow" },
    mjs: { glyph: "\u{E718}", colour: "yellow" },
    cjs: { glyph: "\u{E718}", colour: "yellow" },
    ts: { glyph: "\u{E628}", colour: "blue" },
    tsx: { glyph: "\u{E628}", colour: "blue" },
    html: { glyph: "\u{E612}", colour: "orange" },
    css: { glyph: "\u{E60E}", colour: "blue" },
    scss: { glyph: "\u{E60E}", colour: "blue" },
    qml: { glyph: "\u{F0219}", colour: "fg" },

    sh: { glyph: "\u{E795}", colour: "green" },
    bash: { glyph: "\u{E795}", colour: "green" },
    zsh: { glyph: "\u{E795}", colour: "green" },
    fish: { glyph: "\u{E795}", colour: "green" },

    md: { glyph: "\u{E609}", colour: "fg" },
    markdown: { glyph: "\u{E609}", colour: "fg" },
    txt: { glyph: "\u{F0224}", colour: "fg" },
    pdf: { glyph: "\u{F0226}", colour: "red" },

    png: { glyph: "\u{F021F}", colour: "magenta" },
    jpg: { glyph: "\u{F021F}", colour: "magenta" },
    jpeg: { glyph: "\u{F021F}", colour: "magenta" },
    gif: { glyph: "\u{F021F}", colour: "magenta" },
    svg: { glyph: "\u{F021F}", colour: "magenta" },
    webp: { glyph: "\u{F021F}", colour: "magenta" },
    ico: { glyph: "\u{F021F}", colour: "magenta" },

    mp3: { glyph: "\u{F0223}", colour: "cyan" },
    flac: { glyph: "\u{F0223}", colour: "cyan" },
    wav: { glyph: "\u{F0223}", colour: "cyan" },
    ogg: { glyph: "\u{F0223}", colour: "cyan" },

    mp4: { glyph: "\u{F022B}", colour: "cyan" },
    mkv: { glyph: "\u{F022B}", colour: "cyan" },
    webm: { glyph: "\u{F022B}", colour: "cyan" },
    mov: { glyph: "\u{F022B}", colour: "cyan" },

    zip: { glyph: "\u{F05C4}", colour: "yellow" },
    gz: { glyph: "\u{F05C4}", colour: "yellow" },
    xz: { glyph: "\u{F05C4}", colour: "yellow" },
    zst: { glyph: "\u{F05C4}", colour: "yellow" },
    bz2: { glyph: "\u{F05C4}", colour: "yellow" },
    tar: { glyph: "\u{F05C4}", colour: "yellow" },
    "7z": { glyph: "\u{F05C4}", colour: "yellow" },
    rar: { glyph: "\u{F05C4}", colour: "yellow" }
};

// The last dot only, so "flake.lock" is a lock and "backup.tar.gz" is an
// archive by its "gz". A leading dot is a hidden file, not an extension:
// ".bashrc" has no type to report, which is why the search starts at 1.
function extensionOf(name) {
    const cut = name.lastIndexOf(".");
    return cut <= 0 ? "" : name.slice(cut + 1).toLowerCase();
}

function entryFor(entry) {
    if (entry.isDir)
        return { glyph: FOLDER, colour: "accent" };

    const known = BY_EXTENSION[extensionOf(entry.name)];
    return known ? known : { glyph: FILE, colour: "fg" };
}

function glyphFor(entry) {
    return entryFor(entry).glyph;
}

function colourFor(entry) {
    return entryFor(entry).colour;
}
