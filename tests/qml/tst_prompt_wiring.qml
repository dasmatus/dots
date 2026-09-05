// Reachability tests for the sandbox permission prompt, tst_pill_wiring.qml's
// own pattern: proves sandbox/Prompt.qml and qml/shell.qml actually wire
// together the way the task brief requires — the IpcHandler target, the
// shell.qml registration, and the one non-negotiable a unit test on
// sandbox/policy.js alone cannot reach: that "allow once" is never written
// to disk while "allow always" is.
//
// qmltestrunner cannot instantiate Prompt.qml or shell.qml: both reach
// PanelWindow/IpcHandler/WlrLayershell, Quickshell types tests/README.md
// rules out — so this reads the shipped source as text instead, the same
// XHR idiom tst_pill_wiring.qml and tst_settings_wiring.qml use.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "PromptWiring"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function promptSource() {
        return readSource("../../nix/home/desktop/quickshell/qml/sandbox/Prompt.qml");
    }

    function shellSource() {
        return readSource("../../nix/home/desktop/quickshell/qml/shell.qml");
    }

    // Registered once in shell.qml alongside the other singleton surfaces —
    // osd and settings are the model the task brief names explicitly.
    function test_shell_registers_prompt_alongside_osd_and_settings() {
        const src = shellSource();
        verify(src.indexOf('import "sandbox"') !== -1, "shell.qml must import the sandbox/ directory");
        verify(src.indexOf('import "osd"') !== -1 && src.indexOf('import "settings"') !== -1, "osd and settings must still be the pattern this follows");
        verify(src.indexOf("Prompt {}") !== -1, "shell.qml must instantiate Prompt {} as a single-instance surface");
    }

    function test_ipc_target_is_sandboxprompt() {
        verify(promptSource().indexOf('target: "sandboxprompt"') !== -1, 'the IpcHandler must register under target "sandboxprompt", matching rust/dots-sandbox/src/broker.rs\'s gui_prompt call');
    }

    function test_ask_function_exists_and_returns_bool() {
        const src = promptSource();
        verify(src.indexOf("function ask(appId: string, capability: string): bool {") !== -1, "ask() must take both the app id and the capability, and answer bool the way qs ipc call reads a reply");
    }

    // The non-negotiable a unit test on policy.js alone cannot see:
    // allowOnce()/deny() must never reach overridesFile.setText, and
    // allowAlways() must be the only one of the three that does — proven
    // here by slicing out each function's own body and checking it in
    // isolation, not just that the string "setText" appears somewhere in
    // the file.
    function test_allow_once_never_persists() {
        const body = Scan.blockAfter(promptSource(), "function allowOnce(): void {");
        verify(body !== "", "allowOnce must be a real function");
        verify(body.indexOf("setText") === -1, "allow once must never write to overridesFile — rust/dots-sandbox/src/policy.rs's own PolicyState enum already refuses a persisted allow-once, and this page must not undermine that by writing the SAME effect through a different door");
    }

    function test_deny_never_persists() {
        const body = Scan.blockAfter(promptSource(), "function deny(): void {");
        verify(body !== "", "deny must be a real function");
        verify(body.indexOf("setText") === -1, "deny must never write to overridesFile either — a denial is a one-shot answer, not a standing policy change");
    }

    function test_allow_always_is_the_only_one_that_writes_the_overrides_file() {
        const body = Scan.blockAfter(promptSource(), "function allowAlways(): void {");
        verify(body !== "", "allowAlways must be a real function");
        verify(body.indexOf("overridesFile.setText(") !== -1, "allow always must persist to overridesFile — it is the one answer meant to outlive this single request");
        verify(body.indexOf("Policy.withCapabilityOverride(") !== -1, "the write must narrow through the shared merge helper, never replace the whole overrides file");
    }

    // The one-shot cache is what "allow once" actually means here (see
    // Prompt.qml's own header comment on why a literal blocking wait would
    // deadlock the shell) — every recorded answer must be consumed, not
    // merely read, or a single click could silently answer more than one
    // future request.
    function test_ask_consumes_the_pending_answer_rather_than_just_reading_it() {
        const ask = Scan.blockAfter(promptSource(), "function ask(appId: string, capability: string): bool {");
        verify(ask !== "", "ask must be a real function");
        verify(ask.indexOf("delete next[key]") !== -1, "a cached answer must be deleted once read, or the SAME click could answer a second, later request it was never actually asked about");
        verify(ask.indexOf("root.show(") !== -1, "with no cached answer, ask() must show the prompt for the human to decide the NEXT attempt");
        verify(ask.indexOf("return false;") !== -1, "with no cached answer yet, ask() must deny the CURRENT request rather than guess allow — a synchronous IPC call cannot honestly wait for the click that would justify allowing it (see this file's own header)");
    }
}
