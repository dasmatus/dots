// Network pill's write path: which access point a click connects to
// directly, which one it stops at a passphrase field for, and how the list
// itself is ordered.
//
// "logic" runs network.js over plain objects standing in for WifiNetwork,
// with no D-Bus and no real access point, for the reason battery.js and
// focusedwindow.js give in tests/README.md: Network.qml itself binds
// Quickshell.Networking, which qmltestrunner cannot instantiate.
//
// "wiring" reads Network.qml as text, the idiom tst_focusedwindow_wiring.qml
// and tst_idle.qml's own final section use for the same reason: a correct
// needsPassword() proves nothing about whether the component calls it
// before connecting, or connects with no password at all regardless.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/bar/network.js" as NetworkMath
import "sourcescan.js" as Scan

TestCase {
    name: "Network"

    // ---- signalBars ----

    function test_signalBars_follows_the_installers_own_thresholds_data() {
        return [
            { tag: "no signal", strength: 0, expected: "▂___" },
            { tag: "at the first threshold", strength: 24, expected: "▂___" },
            { tag: "just past it", strength: 25, expected: "▂▄__" },
            { tag: "at the second threshold", strength: 49, expected: "▂▄__" },
            { tag: "at the third threshold", strength: 74, expected: "▂▄▆_" },
            { tag: "full signal", strength: 100, expected: "▂▄▆█" }
        ];
    }

    function test_signalBars_follows_the_installers_own_thresholds(row) {
        compare(NetworkMath.signalBars(row.strength), row.expected, row.tag);
    }

    // ---- needsPassword ----

    function test_needsPassword_data() {
        return [
            { tag: "open and unknown", known: false, isOpen: true, expected: false },
            { tag: "open and known", known: true, isOpen: true, expected: false },
            { tag: "secured and known", known: true, isOpen: false, expected: false },
            { tag: "secured and unknown", known: false, isOpen: false, expected: true }
        ];
    }

    function test_needsPassword(row) {
        compare(NetworkMath.needsPassword(row.known, row.isOpen), row.expected, row.tag);
    }

    // ---- sortNetworks ----

    function test_sortNetworks_puts_the_connected_network_first_regardless_of_signal() {
        const weak = { name: "weak-but-connected", connected: true, signalStrength: 10 };
        const strong = { name: "strong-but-not-connected", connected: false, signalStrength: 90 };

        const sorted = NetworkMath.sortNetworks([strong, weak]);

        compare(sorted[0].name, "weak-but-connected");
        compare(sorted[1].name, "strong-but-not-connected");
    }

    function test_sortNetworks_otherwise_orders_by_strongest_signal_first() {
        const low = { name: "low", connected: false, signalStrength: 20 };
        const high = { name: "high", connected: false, signalStrength: 80 };
        const mid = { name: "mid", connected: false, signalStrength: 50 };

        const sorted = NetworkMath.sortNetworks([low, high, mid]);

        compare(sorted.map(n => n.name), ["high", "mid", "low"]);
    }

    // Live D-Bus state backs the array a real caller hands in; sorting must
    // never touch it.
    function test_sortNetworks_does_not_mutate_the_array_it_was_given() {
        const original = [
            { name: "a", connected: false, signalStrength: 1 },
            { name: "b", connected: false, signalStrength: 99 }
        ];

        NetworkMath.sortNetworks(original);

        compare(original.map(n => n.name), ["a", "b"], "the input array's own order must be untouched");
    }

    // ---- connectionErrorMessage ----

    function test_connectionErrorMessage_names_a_bad_password_data() {
        return [
            { tag: "no secrets", reason: "NoSecrets" },
            { tag: "auth timeout", reason: "WifiAuthTimeout" }
        ];
    }

    function test_connectionErrorMessage_names_a_bad_password(row) {
        compare(NetworkMath.connectionErrorMessage(row.reason), "wrong password", row.tag);
    }

    function test_connectionErrorMessage_distinguishes_a_lost_network_from_a_bad_password() {
        const lost = NetworkMath.connectionErrorMessage("WifiNetworkLost");
        const badPassword = NetworkMath.connectionErrorMessage("NoSecrets");

        verify(lost !== badPassword, "a network going out of range is not the same failure as a wrong password");
    }

    function test_connectionErrorMessage_falls_back_for_an_unrecognised_reason() {
        compare(NetworkMath.connectionErrorMessage("Unknown"), "could not connect");
    }

    // ---- wiring ----

    function networkSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../nix/home/desktop/quickshell/qml/bar/Network.qml"), false);
        xhr.send();
        compare(xhr.status, 200, "Network.qml must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function test_the_pill_opens_a_popup_on_click() {
        const src = networkSource();

        verify(src.indexOf("interactive: true") !== -1, "the pill must accept a click");
        verify(src.indexOf("onClicked: root.expanded = !root.expanded") !== -1, "a click must toggle the popup");
    }

    // Pins the exact selection rule this file's own header explains: open
    // air and an already-known profile connect directly, everything else
    // waits on a passphrase.
    function test_selectNetwork_checks_needsPassword_before_connecting() {
        const body = Scan.blockAfter(networkSource(), "function selectNetwork(network) {");

        verify(body !== "", "selectNetwork must exist");
        verify(body.indexOf("NetworkMath.needsPassword(network.known, isOpen)") !== -1, "must ask needsPassword before deciding");
        verify(body.indexOf("network.connect()") !== -1, "the non-password branch must call connect()");
    }

    function test_the_password_field_calls_connectWithPsk() {
        verify(networkSource().indexOf("root.passwordTarget.connectWithPsk(text)") !== -1, "accepting the password field must call connectWithPsk on the pending network");
    }

    // The regression this guards against: a Connections block whose target
    // never updates would keep listening to whatever network was first
    // clicked, and a second failed attempt on a different network would
    // silently report nothing.
    function test_the_failure_listener_retargets_to_whichever_network_is_pending() {
        const body = Scan.blockAfter(networkSource(), "Connections {");

        verify(body !== "", "a Connections block must exist");
        verify(body.indexOf("target: root.passwordTarget") !== -1, "it must track root.passwordTarget, not a network captured once");
        verify(body.indexOf("NetworkMath.connectionErrorMessage(ConnectionFailReason.toString(reason))") !== -1, "a failure must be translated through connectionErrorMessage");
    }

    function test_the_popup_is_its_own_layer_shell_surface() {
        const src = networkSource();

        verify(src.indexOf("WlrLayershell.namespace: \"dots-network\"") !== -1, "the popup needs its own namespace, distinct from every other overlay");
        verify(src.indexOf("PanelWindow {") !== -1, "the popup must be a real top-level surface, not an Item drawn over the bar");
    }
}
