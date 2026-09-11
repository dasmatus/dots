// Pure logic behind Network.qml's write path: which access point a click
// should connect to directly, and which one it should stop at a passphrase
// field for first.
//
// Split out for the reason battery.js and focusedwindow.js give in
// tests/README.md: Network.qml itself binds Quickshell.Networking, which
// qmltestrunner cannot instantiate. Everything here runs over plain
// booleans, numbers and strings, so a test needs no D-Bus and no real
// access point.
.pragma library

// installer/Network.qml's own thresholds, reused rather than reinvented:
// Quickshell's WifiNetwork.signalStrength is documented nowhere beyond its
// C++ type (a bare double), and every value this repo has actually read off
// it lands in the same 0-100 range nmcli's SIGNAL field does, because both
// read the same NetworkManager D-Bus property underneath.
function signalBars(strength) {
    if (strength <= 24)
        return "▂___";

    if (strength <= 49)
        return "▂▄__";

    if (strength <= 74)
        return "▂▄▆_";

    return "▂▄▆█";
}

// Whether picking this network should go straight to connect() (open air,
// or NetworkManager already holds a saved profile for it) or has to stop at
// a passphrase field first. Takes plain booleans rather than a WifiNetwork
// and a WifiSecurityType value: the caller already has the real enum in
// scope to compare against Open, and handing that comparison's result in
// here instead is what keeps this file free of any Quickshell import.
function needsPassword(known, isOpen) {
    return !known && !isOpen;
}

// Connected first, then strongest signal first: the order a person actually
// wants to choose from, not whatever order the D-Bus model happened to hand
// the list back in. A copy, never the list handed in — Networking.qml's own
// model backs the caller's array, and sorting that in place would reorder
// live D-Bus state out from under whatever else is reading it.
function sortNetworks(networks) {
    return networks.slice().sort((a, b) => {
        if (a.connected !== b.connected)
            return a.connected ? -1 : 1;

        return (b.signalStrength ?? 0) - (a.signalStrength ?? 0);
    });
}

// ConnectionFailReason.toString()'s own names, turned into something a
// person holding a passphrase field can act on. Takes the string
// Quickshell's own toString() already produced rather than the enum value
// itself, for the same reason needsPassword takes booleans: the caller has
// the real type in scope, this file does not need it.
function connectionErrorMessage(reasonName) {
    if (reasonName === "NoSecrets" || reasonName === "WifiAuthTimeout")
        return "wrong password";

    if (reasonName === "WifiNetworkLost")
        return "network went out of range";

    if (reasonName === "WifiClientDisconnected" || reasonName === "WifiClientFailed")
        return "connection failed";

    return "could not connect";
}
