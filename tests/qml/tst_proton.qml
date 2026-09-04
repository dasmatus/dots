// Pins the Proton setup page (nix/home/desktop/quickshell/qml/settings/Proton.qml)
// and the page switching it needs from Settings.qml.
//
// Read as text rather than instantiated: both files reach Quickshell.Io,
// which qmltestrunner cannot load (tests/README.md), the same idiom
// tst_interaction_grammar.qml and tst_chrome_geometry.qml use. Assertions run
// against comment-stripped source so that prose describing a rule cannot
// stand in for the code implementing it.
//
// The assertion that earns this file is the last one. Proton.qml writes three
// lines to proton-setup's stdin and nix/home/proton/proton-setup.nix reads three
// lines back, and nothing but agreement between two files in different
// languages keeps them in the same order. Swap two lines on either side and
// the password is sent as the username: no parse error, no crash, just a
// failed login and a password handed to a field that logs it as a username on
// the way to Proton.
import QtQuick
import QtTest
import "sourcescan.js" as SourceScan

TestCase {
    name: "Proton"

    readonly property string protonQml: "../../nix/home/desktop/quickshell/qml/settings/Proton.qml"
    readonly property string settingsQml: "../../nix/home/desktop/quickshell/qml/settings/Settings.qml"
    readonly property string setupNix: "../../nix/home/proton/proton-setup.nix"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    function readCode(relPath) {
        return SourceScan.stripComments(readSource(relPath));
    }

    // Every `command:` binding or assignment in the file, as the text between
    // the brackets. Both spellings are here because Proton.qml declares one
    // Process's command as a binding and assigns the other's imperatively.
    function commandArgs(src) {
        const out = [];
        const re = /command\s*[:=]\s*\[([^\]]*)\]/g;
        let m = re.exec(src);
        while (m !== null) {
            out.push(m[1]);
            m = re.exec(src);
        }
        return out;
    }

    // A secret must never reach a process argument list: argv is world
    // readable through ps, so a password there is a password shown to every
    // other process on the machine. Proton.qml is supposed to send both over
    // stdin and put only literals in the command.
    function test_no_secret_reaches_a_command_argument() {
        const args = commandArgs(readCode(protonQml));
        verify(args.length > 0, "expected at least one Process command in Proton.qml");

        for (let i = 0; i < args.length; i++) {
            const arg = args[i];
            verify(arg.indexOf("password") === -1, `command argument list carries the password: [${arg}]`);
            verify(arg.indexOf("totp") === -1, `command argument list carries the TOTP code: [${arg}]`);
        }
    }

    // The counterpart to the above: the secrets do go somewhere, and that
    // somewhere is the stdin payload. Without this, deleting the write would
    // satisfy the argv assertion perfectly.
    function test_secrets_travel_on_stdin() {
        const src = readCode(protonQml);
        const payload = SourceScan.stripComments(src).match(/_pendingStdin\s*=\s*`([^`]*)`/);
        verify(payload !== null, "Proton.qml must build a stdin payload for proton-setup");
        verify(payload[1].indexOf("root.password") !== -1, "the stdin payload must carry the password");
        verify(payload[1].indexOf("root.totp") !== -1, "the stdin payload must carry the TOTP code");
    }

    // The contract this file exists for. Proton.qml's payload order and
    // proton-setup's read order have to match, and they live in two files in
    // two languages with nothing but this test between them.
    function test_stdin_field_order_matches_what_the_shell_reads() {
        const payload = readCode(protonQml).match(/_pendingStdin\s*=\s*`([^`]*)`/);
        verify(payload !== null, "Proton.qml must build a stdin payload");

        const sent = payload[1];
        const emailAt = sent.indexOf("emailField.text");
        const passwordAt = sent.indexOf("root.password");
        const totpAt = sent.indexOf("root.totp");
        verify(emailAt !== -1 && passwordAt !== -1 && totpAt !== -1, `payload is missing a field: ${sent}`);
        verify(emailAt < passwordAt, "the payload must send the email before the password");
        verify(passwordAt < totpAt, "the payload must send the password before the TOTP code");

        // The shell side, in the order its `read -r` calls consume them.
        //
        // Comment lines go first, and the pattern is anchored to a line that
        // begins with the real `IFS= read -r`. Both halves are load-bearing:
        // the first draft matched anywhere in the raw file and picked up the
        // prose "read -r so a backslash in a password is a backslash" out of a
        // comment, yielding ["so", "email", "password", "totp"]. That is the
        // failure mode sourcescan.js exists for, but stripComments only knows
        // JS comments, and this file is Nix.
        const reads = [];
        const setup = readSource(setupNix).split("\n").filter(line => line.trim().indexOf("#") !== 0).join("\n");
        const re = /^\s*IFS=\s*read\s+-r\s+(\w+)/gm;
        let m = re.exec(setup);
        while (m !== null) {
            reads.push(m[1]);
            m = re.exec(setup);
        }
        compare(reads, ["email", "password", "totp"], "nix/home/proton/proton-setup.nix must read email, password, then TOTP, in the order Proton.qml sends them");
    }

    // A spent code and a used password have no reason to stay in memory for
    // the rest of the session, and Settings.qml builds this page once rather
    // than per visit, so nothing else would drop them.
    function test_leaving_the_page_clears_the_secrets() {
        const proton = readCode(protonQml);
        const forget = SourceScan.blockAfter(proton, "function forget(): void {");
        verify(forget.indexOf("root.password = \"\"") !== -1, "forget() must clear the password");
        verify(forget.indexOf("root.totp = \"\"") !== -1, "forget() must clear the TOTP code");

        const leave = SourceScan.blockAfter(readCode(settingsQml), "function leaveProton(): void {");
        verify(leave.indexOf("forget()") !== -1, "leaveProton() must call the page's forget()");
    }

    // Enter is overloaded: it saves on a value row and opens a page on the
    // synthetic Proton row. Asserting both halves, because an activate() that
    // always opens the page would pass a check for either one alone.
    function test_enter_opens_the_page_only_on_a_page_row() {
        const activate = SourceScan.blockAfter(readCode(settingsQml), "function activate(): void {");
        verify(activate.indexOf("\"page\"") !== -1, "activate() must test for a page row");
        verify(activate.indexOf("openProton()") !== -1, "activate() must open the Proton page for a page row");
        verify(activate.indexOf("save()") !== -1, "activate() must still save on a value row");
        verify(activate.indexOf("openProton()") < activate.indexOf("save()"), "the page branch must come before the save fallback, or every row would save");
    }

    // Esc on the Proton page steps back to the form. Closing the panel
    // outright would throw away a half-typed login.
    function test_escape_steps_back_before_it_closes() {
        const escape = SourceScan.blockAfter(readCode(settingsQml), "Keys.onEscapePressed: {");
        verify(escape.indexOf("leaveProton()") !== -1, "Esc on the Proton page must return to the form");
        verify(escape.indexOf("window.visible = false") !== -1, "Esc on the form must still close the panel");
        verify(escape.indexOf("leaveProton()") < escape.indexOf("window.visible = false"), "the page check must come first, or Esc would always close");
    }

    // The row the page hangs off. It is synthetic rather than a row from
    // global-settings, because global-settings only dumps and sets values and
    // this row has none.
    function test_the_proton_row_exists_and_is_a_page() {
        const src = readCode(settingsQml);
        const rows = SourceScan.blockAfter(src, "readonly property var rows: root.fields.concat([");
        verify(rows.indexOf("\"proton\"") !== -1, "the row model must carry a proton row");
        verify(rows.indexOf("\"page\"") !== -1, "the proton row must be typed as a page");
    }
}
