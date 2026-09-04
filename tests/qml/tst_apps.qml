// apps.js's desktop-entry string dissection: isWebApp's PWA detection and
// the appKey/actionKey namespacing rank.js's records rely on. The Exec=
// lines below are real, captured from this machine's own
// ~/.local/share/applications/brave-*-Default.desktop files (the EduPage
// and Mastodon PWAs), not invented text — see isWebApp's own header in
// apps.js for why the discriminator has to be the --app-id= flag rather
// than the filename.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/launcher/apps.js" as AppsLogic

TestCase {
    name: "Apps"

    // brave-hjdjgimfpmodogjniomhemdbojjoecoa-Default.desktop's own Exec=
    // line — this machine's actual installed EduPage PWA.
    function realEduPageExec() {
        return "brave --profile-directory=Default --app-id=hjdjgimfpmodogjniomhemdbojjoecoa";
    }

    function test_isWebApp_data() {
        return [
            { tag: "the real EduPage PWA's Exec= line", exec: realEduPageExec(), expected: true },
            { tag: "plain brave, no PWA flag at all", exec: "brave", expected: false },
            { tag: "plain librewolf", exec: "librewolf %u", expected: false },
            { tag: "a lookalike flag: --app-idx= is not --app-id=", exec: "brave --app-idx=hjdjgimfpmodogjniomhemdbojjoecoa", expected: false },
            // --app-id= present, but glued onto the end of another token
            // with no word boundary before it — the case the (^|\s) anchor
            // exists to reject. Without the anchor, a bare
            // /--app-id=/.test() would find this substring and this row
            // would wrongly pass as a PWA.
            { tag: "--app-id= with no word boundary before it", exec: "foo--app-id=bar", expected: false },
            // The anchor's other branch: --app-id= as the very first thing
            // in the string, matched via "^" rather than "\s". Not a shape
            // a real .desktop Exec= line takes (Exec always starts with the
            // binary), but the regex has two alternatives and this is the
            // only row that can tell them apart from each other — dropping
            // "^|" and keeping only "\s" would fail this row while leaving
            // every other row unchanged.
            { tag: "--app-id= as the very first token, the anchor's ^ branch", exec: "--app-id=hjdjgimfpmodogjniomhemdbojjoecoa", expected: true },
            { tag: "undefined Exec=, a malformed entry", exec: undefined, expected: false },
            { tag: "empty Exec=", exec: "", expected: false }
        ];
    }

    // isWebApp must be total: none of these six inputs may throw, and each
    // has to land on the right side of the --app-id= discriminator.
    function test_isWebApp(row) {
        compare(AppsLogic.isWebApp(row.exec), row.expected);
    }

    // Same PWA as realEduPageExec's fixture — entry.id for
    // brave-hjdjgimfpmodogjniomhemdbojjoecoa-Default.desktop is its own
    // filename stem, per Quickshell's DesktopEntry.id.
    function test_appKey_prefixes_the_id_with_the_apps_namespace() {
        compare(AppsLogic.appKey("brave-hjdjgimfpmodogjniomhemdbojjoecoa-Default"), "apps:brave-hjdjgimfpmodogjniomhemdbojjoecoa-Default");
    }

    // The Mastodon PWA's real "Compose new post" action, from
    // brave-ikigfogfljecogfmdkeiipdcamdbibjl-Default.desktop's own
    // [Desktop Action Compose-new-post] section.
    function test_actionKey_prefixes_the_id_and_names_the_action() {
        compare(AppsLogic.actionKey("brave-ikigfogfljecogfmdkeiipdcamdbibjl-Default", "Compose-new-post"), "apps:brave-ikigfogfljecogfmdkeiipdcamdbibjl-Default:action:Compose-new-post");
    }
}
