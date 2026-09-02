// Shared source-text scanning for the tests that assert against shipped QML
// as text rather than by instantiating it. Several surfaces reach
// Quickshell.Io, which qmltestrunner cannot load (see tests/README.md), so
// those assertions read the file and look for the binding they expect.
//
// That idiom has one failure mode, and it has already bitten once: a comment
// mentioning `panel.implicitHeight` satisfied an assertion meant for the
// binding of the same name, so gutting the real binding left the test green.
// Stripping comments first is what closes it, and this lives in one place
// because two copies of the rule would drift and the stale one would be the
// one still passing.
.pragma library

// Removes // and /* */ comments and leaves every string literal — including
// template literals — exactly as it found them.
//
// A left-to-right character scan rather than a regex. The regex this
// replaced guarded "..." and '...' but not backticks, which broke both ways:
// a // inside a template literal (`https://…`) opened a comment match that
// ate the rest of the line, deleting real code, and a lone apostrophe inside
// one (`Chrome's panel`) opened a string match that ran forward past a real
// comment, which then survived the strip and could stand in for a binding
// again. Both are one edit away in files that already use template literals.
//
// Two constructs it deliberately does not model, neither of which appears in
// any file scanned today:
//   - a substitution inside a template literal (`${...}`) is treated as
//     template text, so a comment written inside one survives. That is the
//     safe direction: it preserves, it never deletes.
//   - a regex literal containing a quote (/["]/) would be read as opening a
//     string. Distinguishing a regex from division needs the preceding token,
//     which is more parser than this needs to be.
function stripComments(src) {
    let out = "";
    let i = 0;

    while (i < src.length) {
        const c = src[i];

        if (c === '"' || c === "'" || c === "`") {
            const quote = c;
            out += c;
            i++;
            while (i < src.length) {
                if (src[i] === "\\") {
                    out += src[i] + (src[i + 1] || "");
                    i += 2;
                    continue;
                }
                out += src[i];
                i++;
                if (src[i - 1] === quote)
                    break;
            }
            continue;
        }

        if (c === "/" && src[i + 1] === "/") {
            while (i < src.length && src[i] !== "\n")
                i++;
            continue;
        }

        if (c === "/" && src[i + 1] === "*") {
            i += 2;
            while (i < src.length && !(src[i] === "*" && src[i + 1] === "/"))
                i++;
            i += 2;
            continue;
        }

        out += c;
        i++;
    }

    return out;
}

// The brace-matched body of the block `marker` opens, marker included.
// Returns "" when the marker is absent, so a caller can tell "no such block"
// from "a block that does not say what it should" and fail with the right
// message. `marker` must end with the block's opening brace.
function blockAfter(src, marker) {
    const start = src.indexOf(marker);
    if (start === -1)
        return "";

    let depth = 1;
    let i = start + marker.length;
    while (depth > 0 && i < src.length) {
        if (src[i] === "{")
            depth++;
        else if (src[i] === "}")
            depth--;
        i++;
    }

    return depth === 0 ? src.slice(start, i) : "";
}
