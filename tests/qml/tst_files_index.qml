// The preindexed `/` search, driven with captured index lines and plain
// objects. No Process, no filesystem, no compositor.
//
// The index is the same `%Y\t%s\t%T@\t%P` text `find` already emits for a
// live search, written to a file ahead of time by a systemd unit, so
// files.js's parseListing reads it unchanged and these tests only cover
// what is new: turning a query into one grep argv, and turning grep's
// $HOME-relative output back into entries that know where they live.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/files/index.js" as Index

TestCase {
    name: "FilesIndex"

    readonly property string home: "/home/matus"

    function line(type, path) {
        return `${type}\t10\t1756819200\t${path}\n`;
    }

    // `*` and `?` are the wildcards files.js has always documented as
    // deliberate, and they survive the move from `find -iname` to grep.
    function test_globtoregex_keeps_the_two_wildcards_find_supported() {
        compare(Index.globToRegex("*.md"), ".*\\.md");
        compare(Index.globToRegex("tst_?iles"), "tst_.iles");
    }

    // Everything else a regex would read as syntax becomes a literal, so a
    // query is matched as the text it looks like.
    function test_globtoregex_escapes_every_other_metacharacter() {
        compare(Index.globToRegex("a+b"), "a\\+b");
        compare(Index.globToRegex("f(x)"), "f\\(x\\)");
        compare(Index.globToRegex("^a$"), "\\^a\\$");
        compare(Index.globToRegex("a|b"), "a\\|b");
        compare(Index.globToRegex("a{2}"), "a\\{2\\}");
        compare(Index.globToRegex("a\\b"), "a\\\\b");
        // A slash is left alone. It is not an ERE metacharacter, escaping
        // an ordinary character is undefined in POSIX ERE, and the anchor
        // below already confines a match to one path segment.
        compare(Index.globToRegex("a/b"), "a/b");
    }

    // A deliberate narrowing, not an oversight. `find -iname '*[test]*'`
    // reads the brackets as a glob character class, which on this tree
    // matches 275067 of 299569 entries while exactly one real filename
    // contains a literal `[`. Nobody typing a bracket into a search line
    // means "any of these letters".
    function test_globtoregex_treats_a_bracket_as_a_literal_bracket() {
        compare(Index.globToRegex("[test]"), "\\[test\\]");
    }

    // One process, one argv, no shell — the same discipline the live
    // search and every write operation in this file manager already keep.
    function test_indexargv_is_a_single_grep_with_no_shell_anywhere() {
        const argv = Index.indexArgv("/c/all.tsv", "report", 2000);

        compare(argv[0], "grep");
        compare(argv[argv.length - 1], "/c/all.tsv");
        verify(argv.indexOf("-i") > 0);
        verify(argv.indexOf("-E") > 0);
        // `--` so a query starting with a dash is a pattern, not a flag.
        verify(argv.indexOf("--") > 0);
        for (const arg of argv)
            verify(arg.indexOf("|") === -1 && arg.indexOf(";") === -1);
    }

    // Bounded work per keystroke. Without it a one-character query walks
    // every one of the index's 300k lines and hands them all to QML.
    function test_indexargv_caps_how_many_lines_grep_will_match() {
        const argv = Index.indexArgv("/c/all.tsv", "e", 2000);

        compare(argv[argv.indexOf("-m") + 1], "2000");
    }

    // `-iname` matched the basename only, and the anchor is what keeps
    // that true against a file of full relative paths: the query has to
    // land after the last slash on the line.
    function test_indexargv_matches_the_last_path_segment_only() {
        const pattern = Index.indexArgv("/c/all.tsv", "report", 200)[Index.indexArgv("/c/all.tsv", "report", 200).indexOf("--") + 1];

        verify(pattern.indexOf("report") > 0);
        verify(pattern.indexOf("[^/") > 0);
        compare(pattern.charAt(pattern.length - 1), "$");
    }

    // Two files, because the dotfile prune costs nothing at query time if
    // the pruning already happened when the index was built.
    function test_indexfor_picks_the_dotfile_free_file_unless_showing_them() {
        compare(Index.indexFor(false, "/c/all.tsv", "/c/visible.tsv"), "/c/visible.tsv");
        compare(Index.indexFor(true, "/c/all.tsv", "/c/visible.tsv"), "/c/all.tsv");
    }

    // The index only covers $HOME, so this is the predicate that decides
    // whether `/` can use it at all or has to fall back to a live walk.
    function test_withinhome_accepts_home_and_its_children_only() {
        verify(Index.withinHome("/home/matus", this.home));
        verify(Index.withinHome("/home/matus/Dokumente", this.home));
        verify(!Index.withinHome("/etc", this.home));
        verify(!Index.withinHome("/", this.home));
        // A sibling that merely shares the prefix is not inside it.
        verify(!Index.withinHome("/home/matuska", this.home));
    }

    // grep hands back a path relative to $HOME. A row has to show a name
    // and open the right file, so the path is split once, here, rather
    // than re-derived at every use.
    function test_locate_splits_a_relative_path_into_a_name_and_a_home() {
        const parsed = [{ name: "Dokumente/dots/flake.nix", isDir: false, size: 10, mtime: 1 }];

        const located = Index.locate(parsed, this.home, this.home);

        compare(located[0].name, "flake.nix");
        compare(located[0].dir, "/home/matus/Dokumente/dots");
        compare(located[0].where, "Dokumente/dots");
        compare(located[0].isDir, false);
    }

    // An entry sitting directly in $HOME has no parent to name, and "~"
    // says where it is without an empty column.
    function test_locate_names_the_home_directory_itself() {
        const located = Index.locate([{ name: "notes.txt", isDir: false }], this.home, this.home);

        compare(located[0].name, "notes.txt");
        compare(located[0].dir, this.home);
        compare(located[0].where, "~");
    }

    // The fallback walk outside $HOME returns paths relative to the
    // directory it searched rather than to $HOME, which is why the base
    // and the home are two arguments and not one.
    function test_locate_takes_its_base_and_its_home_separately() {
        const located = Index.locate([{ name: "ssh/sshd_config", isDir: false }], "/etc", this.home);

        compare(located[0].name, "sshd_config");
        compare(located[0].dir, "/etc/ssh");
        compare(located[0].where, "/etc/ssh");
    }

    // The pane's own listing is already basenames in a known directory, so
    // it reaches the same shape without a split.
    function test_locateat_attaches_a_directory_to_a_plain_listing() {
        const located = Index.locateAt([{ name: "draft.md", isDir: false }], "/home/matus/Dokumente", this.home);

        compare(located[0].name, "draft.md");
        compare(located[0].dir, "/home/matus/Dokumente");
        compare(located[0].where, "Dokumente");
    }

    // Outside $HOME there is nothing to be relative to, so the display
    // falls back to the absolute directory rather than a wrong "~" path.
    function test_locateat_shows_an_absolute_directory_outside_home() {
        compare(Index.locateAt([{ name: "hosts" }], "/etc", this.home)[0].where, "/etc");
    }

    function test_globmatches_filters_a_name_by_the_same_wildcards() {
        verify(Index.globMatches("readme.md", "*.md"));
        verify(Index.globMatches("readme.md", "READ"));
        verify(!Index.globMatches("readme.md", "*.txt"));
        // An empty query matches everything, which is what the line shows
        // before anything is typed.
        verify(Index.globMatches("anything", ""));
    }

    // The index is up to ten minutes old. The pane's listing is live, so a
    // file saved a moment ago is findable through it even though the index
    // has never seen it.
    function test_merge_keeps_the_live_entry_when_both_sides_have_it() {
        const index = Index.locate([{ name: "Dokumente/draft.md", isDir: false, size: 1 }], this.home, this.home);
        const live = Index.locateAt([{ name: "draft.md", isDir: false, size: 999 }], "/home/matus/Dokumente", this.home);

        const merged = Index.merge(index, live, "/home/matus/Dokumente", "draft", 200);

        compare(merged.length, 1);
        compare(merged[0].size, 999);
    }

    function test_merge_caps_the_rows_it_returns() {
        const many = [];
        for (let i = 0; i < 500; i++)
            many.push({ name: `f${i}.txt`, dir: this.home, where: "~", isDir: false });

        compare(Index.merge(many, [], this.home, "f", 200).length, 200);
    }

    // The case the other ranking tests could not see, because each of them
    // put both candidates under the same directory.
    //
    // Typing a whole filename makes every hit an exact match, so a rank
    // that scored exactness before location collapsed them all into one
    // tier and fell through to depth — and answered a search for main.rs
    // run inside this repo's rust/ with six main.rs files from six other
    // projects and none of its own.
    function test_rank_puts_the_current_directory_first_even_when_every_name_is_exact() {
        const entries = [
            { name: "main.rs", dir: "/home/matus/other/xtask/src", isDir: false },
            { name: "main.rs", dir: "/home/matus/dots/rust/installer-tui/src", isDir: false }
        ];

        compare(Index.rank(entries, "main.rs", "/home/matus/dots/rust")[0].dir, "/home/matus/dots/rust/installer-tui/src");
    }

    // An exact hit outranks a longer one that merely starts with it, once
    // location has already been accounted for.
    function test_rank_puts_an_exact_name_match_first() {
        const entries = [
            { name: "flake.nix.bak", dir: "/home/matus/a", isDir: false },
            { name: "flake.nix", dir: "/home/matus/b/c/d", isDir: false }
        ];

        compare(Index.rank(entries, "flake.nix", "/home/matus")[0].name, "flake.nix");
    }

    // `/` searches all of $HOME now, so without this a search run inside a
    // project answers from everywhere in no useful order.
    function test_rank_puts_hits_under_the_current_directory_first() {
        const entries = [
            { name: "main.rs", dir: "/home/matus/other", isDir: false },
            { name: "main.rs", dir: "/home/matus/dots/rust", isDir: false }
        ];

        const ranked = Index.rank(entries, "main", "/home/matus/dots");

        compare(ranked[0].dir, "/home/matus/dots/rust");
    }

    function test_rank_prefers_a_prefix_match_over_a_mere_substring() {
        const entries = [
            { name: "my-report.md", dir: "/home/matus", isDir: false },
            { name: "report.md", dir: "/home/matus", isDir: false }
        ];

        compare(Index.rank(entries, "report", "/home/matus")[0].name, "report.md");
    }

    // Between two otherwise equal hits the shallower one is the one you
    // filed deliberately; the deep one is usually inside a build tree.
    function test_rank_prefers_the_shallower_path() {
        const entries = [
            { name: "config.toml", dir: "/home/matus/a/b/c/d/e", isDir: false },
            { name: "config.toml", dir: "/home/matus/a", isDir: false }
        ];

        compare(Index.rank(entries, "config", "/home/matus")[0].dir, "/home/matus/a");
    }

    // grep's own exit codes are the only signal that the index file is not
    // there yet, which is the whole of a first boot before the unit runs.
    function test_missing_index_is_told_apart_from_simply_no_matches() {
        verify(Index.indexUnavailable(2));
        verify(!Index.indexUnavailable(0));
        verify(!Index.indexUnavailable(1));
    }
}
