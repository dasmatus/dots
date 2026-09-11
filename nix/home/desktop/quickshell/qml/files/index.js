// Serving `/` from a prebuilt index instead of walking the tree per
// keystroke. Pure, so tests/qml/tst_files_index.qml drives all of it with
// captured lines and no Process, filesystem or compositor.
//
// The index is a file of exactly the lines files.js's searchArgv already
// produces, `%Y\t%s\t%T@\t%P` relative to $HOME, written ahead of time by the
// dots-files-index systemd unit. That format identity is the point:
// parseListing reads the index without knowing it is one, so nothing
// downstream had to learn a second shape.
//
// Measured on this tree, 299569 entries under $HOME: the live walk costs
// 0.24s per query with dotfiles pruned and 0.89s with them shown, while a
// grep over the index costs between nothing and 0.11s and does not care
// which of the two it is. Building the index costs 1.47s, once.
//
// Query time is one process with one argv and no shell, the same rule the
// live search and every write operation in this file manager keep. That is
// what forces the matching into grep rather than a pipeline, and the glob
// translation below into a pure function rather than a quoting exercise.
.pragma library

// The glob `find -iname` accepted, rewritten as the POSIX ERE grep wants.
//
// `*` and `?` survive because files.js documented them as deliberate: a
// query containing one is a wildcard, which is worth having rather than
// escaping away. Everything else a regex would read as syntax becomes a
// literal.
//
// Brackets are the one place this narrows what `find` did, on purpose.
// `-iname '*[test]*'` reads them as a glob character class, so `/[test]`
// matches 275067 of this tree's 299569 entries, while exactly one real
// filename anywhere under $HOME contains a literal `[`. Nobody typing a
// bracket into a search line means "any of these letters".
//
// A slash is left alone rather than escaped. It is not a metacharacter,
// escaping an ordinary character is undefined in POSIX ERE, and the
// segment anchor in indexArgv already means a query containing a slash
// matches nothing, exactly as it matched nothing through `-iname`.
var ESCAPED = ".^$+{}()|[]\\";

function globToRegex(query) {
    let out = "";

    for (const character of query) {
        if (character === "*")
            out += ".*";
        else if (character === "?")
            out += ".";
        else if (ESCAPED.indexOf(character) >= 0)
            out += "\\" + character;
        else
            out += character;
    }

    return out;
}

// One grep over one index file.
//
// The pattern is anchored to the last path segment because `-iname`
// matched the basename only, and the index holds full relative paths: a
// bare substring would make a query match any directory on the way down.
// The leading tab is the field separator parseListing splits on, so the
// match starts where the path does and cannot stray into the size or
// mtime column.
//
// `-m` is not a display cap. searchCap in Files.qml is that. It bounds
// how much work grep does at all: a one-character query matches almost
// every line of a 300k-line file, and reading all of them into QML to
// throw away everything past the first screen is the cost this whole
// change exists to avoid. It does mean the rows shown are the best of the
// first `limit` matched rather than of every match.
//
// `--` so a query starting with a dash stays a pattern.
function indexArgv(indexPath, query, limit) {
    const pattern = `\t[^\t]*${globToRegex(query)}[^/\t]*$`;

    return ["grep", "-i", "-m", String(limit), "-E", "--", pattern, indexPath];
}

// Two index files rather than one filtered at query time: pruning dotfiles
// is what makes the live walk cost 0.24s instead of 0.89s, and doing it
// once when the index is built means the query never pays it.
function indexFor(showHidden, allPath, visiblePath) {
    return showHidden ? allPath : visiblePath;
}

// Whether the index can answer for this directory at all. It covers $HOME
// and nothing else, so anywhere outside falls back to the live walk.
//
// The trailing slash is what stops a sibling that merely shares the prefix,
// /home/matuska against /home/matus, from being treated as inside it.
function withinHome(path, home) {
    return path === home || path.indexOf(home + "/") === 0;
}

// grep's exit codes are the only signal that the index file is missing,
// which is every search taken before the unit has run once. 0 matched, 1
// matched nothing, 2 could not read the file.
function indexUnavailable(exitCode) {
    return exitCode === 2;
}

// What a row shows in place of the directory it lives in. Paths under
// $HOME lose the prefix because every one of them would otherwise carry
// the same twelve characters; "~" names $HOME itself, since an entry
// sitting directly in it has no parent left to print.
function displayDir(dir, home) {
    if (dir === home)
        return "~";

    return withinHome(dir, home) ? dir.slice(home.length + 1) : dir;
}

function located(entry, name, dir, home) {
    return {
        name: name,
        isDir: entry.isDir,
        size: entry.size,
        mtime: entry.mtime,
        dir: dir,
        where: displayDir(dir, home)
    };
}

// Hits whose parsed `name` is a path relative to `base`. Split once here
// rather than re-derived wherever a row is drawn or opened: the row needs
// a basename to title itself and an absolute directory to open against,
// and deriving either at the call site is how a hit three levels down ends
// up opening the wrong file.
//
// `base` and `home` are separate because they differ on the fallback path.
// An index hit is relative to $HOME, so both are $HOME. A hit from the
// live walk outside $HOME is relative to the directory being searched,
// while "~" in the displayed column still has to mean $HOME.
function locate(entries, base, home) {
    return entries.map(entry => {
        const cut = entry.name.lastIndexOf("/");
        const name = cut < 0 ? entry.name : entry.name.slice(cut + 1);
        const parent = cut < 0 ? "" : entry.name.slice(0, cut);

        return located(entry, name, parent === "" ? base : `${base}/${parent}`, home);
    });
}

// The pane's own listing, which is already basenames in a directory it
// knows. Same shape as locate's output so merge can treat both alike.
function locateAt(entries, dir, home) {
    return entries.map(entry => located(entry, entry.name, dir, home));
}

// The glob applied to a single name, for filtering the pane's live listing
// by the query the index was searched with. Unanchored, because `-iname`
// wrapped its pattern in `*` on both sides and an empty query has to match
// everything, which is the state the line is in before anything is typed.
function globMatches(name, query) {
    return new RegExp(globToRegex(query), "i").test(name);
}

// Index hits plus whatever the pane is showing live, deduplicated, ranked
// and capped.
//
// The live listing goes first and wins a tie because the index is up to
// ten minutes old: a file saved a moment ago exists only on that side, and
// where both sides have it the live one carries the size and mtime that
// are actually current.
//
// The seen map has a null prototype on purpose. A plain object inherits
// "constructor" and "__proto__" as truthy keys, and a file named
// `constructor` is not hypothetical in a directory full of JavaScript.
function merge(indexHits, liveHits, cwd, query, cap) {
    const seen = Object.create(null);
    const kept = [];

    for (const entry of liveHits.concat(indexHits)) {
        const key = `${entry.dir}/${entry.name}`;

        if (seen[key])
            continue;

        seen[key] = true;
        kept.push(entry);
    }

    return rank(kept, query, cwd).slice(0, cap);
}

function depthOf(dir) {
    return dir.split("/").length;
}

// Lower is better. Where you are outranks how well the name matched, and
// only then does an exact name beat a prefix and a prefix beat a mere
// substring, the way commands.js already orders the `:` line.
//
// That order is the whole reason a `/` covering all of $HOME is usable from
// inside a project, and getting it the other way round quietly defeats itself.
// Ranking an exact name first put every hit in the same tier the moment a full
// filename was typed, which is the ordinary way to search, so the directory
// you were standing in stopped counting at all. Searching "main.rs" from this
// repo's rust/ then answered with six main.rs files from six other projects
// and none of its own, while four unit tests agreed it was correct, because
// each of them had put both candidates under one directory and so could not
// tell the two orderings apart.
function tierOf(entry, needle, cwd) {
    const lower = entry.name.toLowerCase();

    if (needle === "")
        return 0;

    const elsewhere = withinHome(entry.dir, cwd) ? 0 : 3;

    if (lower === needle)
        return elsewhere;

    return elsewhere + (lower.indexOf(needle) === 0 ? 1 : 2);
}

// Ties break on depth before name: between two files of the same name the
// shallower one is the one that was filed deliberately, and the deep one
// is usually inside a build tree or a vendored dependency.
function rank(entries, query, cwd) {
    const needle = query.toLowerCase();

    return entries.slice().sort((a, b) => {
        const tier = tierOf(a, needle, cwd) - tierOf(b, needle, cwd);
        if (tier !== 0)
            return tier;

        const depth = depthOf(a.dir) - depthOf(b.dir);
        if (depth !== 0)
            return depth;

        return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
    });
}
