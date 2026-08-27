// Entry point for the LiveISO installer, run by the ISO's cage session
// rather than by home-manager's Hyprland one.
//
// A second root, not a mode flag on shell.qml, because the two have nothing
// in common at runtime: cage gives a single output and no window manager to
// query, so every Hyprland import shell.qml relies on for per-monitor bars
// and workspace state would resolve to nothing here. Keeping them apart means
// this file only ever has to describe an install session, never the desktop
// bar it will never sit next to.
//
// FloatingWindow, not PanelWindow: Quickshell backs PanelWindow with the
// zwlr_layer_shell_v1 Wayland protocol, and cage does not implement it (its
// compositor only ever calls wlr_xdg_shell_create and wlr_xwayland_create —
// grep cage's source for layer_shell and it comes back empty). A
// PanelWindow root here would never be mapped and the ISO would boot to a
// blank screen. It needs no anchors: cage maximizes the single toplevel it
// is handed, so implicitWidth/implicitHeight below are only the pre-maximize
// fallback, never the on-screen size. Do not change this back to PanelWindow
// to match the rest of the tree — the rest of the tree runs under Hyprland,
// which does implement layer-shell; this file runs under cage, which does
// not.
//
// implicitWidth/implicitHeight, not width/height: FloatingWindow logs
// "Setting `height` is deprecated. Set `implicitHeight` instead." (and the
// same for width) the moment cage maps it — a runtime warning `qmllint`
// cannot see because it never runs the file, only type-checks it. A clean
// lint is not a clean run.
//
// No Hyprland import: cage has no workspaces or focused-window signal to
// read. No `common`: the shared Panel component is a bordered, padded box
// meant to float inside a PanelWindow (the launcher, the settings form);
// this root is a full-bleed background with no chrome to border, so the
// wizard styles itself from Theme directly, same as this file always has.
//
// `pragma ComponentBehavior: Bound`: every screen Component below reaches
// `window`'s id from inside a nested component, which QML only resolves
// without a runtime warning when this file opts into the stricter binding.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "."
import "installer" as Installer
import "installer/config.js" as Config
import "installer/disks.js" as Disks

ShellRoot {
    FloatingWindow {
        id: window

        color: Theme.bg

        implicitWidth: 1280
        implicitHeight: 800

        // The answers screen collect, one shared object every pushed screen
        // reads and writes in place (a plain JS object, not QML properties:
        // `InstallConfig` in config.rs is passed around the same way, one
        // struct threaded through every `Screen` arm). `wizard` is the one
        // piece of state that never reaches settings.nix — the unconfirmed
        // password app.rs keeps in `pending_password` rather than on
        // `InstallConfig` until UserPasswordConfirm agrees with it.
        property var cfg: Config.defaults()
        property var wizard: ({
                pending: ""
            })

        // Populated by the meminfo -> lsblk -> findmnt -> PKNAME pipeline
        // below, mirroring main.rs running `list_disks()` +
        // `autodetect_disk()` before the TUI ever mounts. `disksReady` gates
        // Welcome's Enter key so Network never asks `autodetectDisk` about a
        // listing that has not landed yet.
        property var disks: []
        property bool diskAuto: false
        property bool disksReady: false

        // Swaps the StackView's current screen for a freshly built one.
        // `replaceCurrentItem` (not push/pop): app.rs's `Screen` transitions
        // are arbitrary jumps in an enum, not a linear history — Confirm's
        // Esc target depends on `disk_auto`, not on "whatever was on top of
        // the stack" — so nothing here should accumulate a back-stack.
        // `props` seeds the handful of values that do not live on `cfg` or
        // `wizard` (a carried SSID, a carried error message) as one-shot
        // initial property values, exactly like main.rs threading state
        // through fresh `Screen` values rather than mutating history.
        function go(component, props) {
            stack.replaceCurrentItem(component, props || {}, StackView.Immediate);
        }

        // after_network() in app.rs: DiskSelect only when autodetection
        // could not pick a single fixed disk; Hostname otherwise.
        function afterNetworkComponent() {
            return window.diskAuto ? hostnameComponent : diskSelectComponent;
        }

        Component.onCompleted: {
            readyMarker.running = true;
            meminfoProc.running = true;
        }

        StackView {
            id: stack

            x: 0
            y: 0
            width: parent.width
            height: parent.height

            initialItem: welcomeComponent
        }

        Component {
            id: welcomeComponent

            Installer.Welcome {
                cfg: window.cfg
                ready: window.disksReady

                onNext: window.go(networkComponent)
                onQuit: Qt.quit()
            }
        }

        Component {
            id: networkComponent

            Installer.Network {
                cfg: window.cfg
                diskAuto: window.diskAuto

                onConnectOpen: ssid => window.go(wifiConnectingComponent, {
                        ssid: ssid
                    })
                onNeedPassword: ssid => window.go(wifiPasswordComponent, {
                        ssid: ssid
                    })
                onSkip: window.go(window.afterNetworkComponent())
                onBack: window.go(welcomeComponent)
            }
        }

        Component {
            id: wifiPasswordComponent

            Installer.WifiPassword {
                onConnectRequested: password => window.go(wifiConnectingComponent, {
                        ssid: ssid
                    })
                onBack: window.go(networkComponent)
            }
        }

        Component {
            id: wifiConnectingComponent

            Installer.WifiConnecting {}
        }

        Component {
            id: diskSelectComponent

            Installer.DiskSelect {
                cfg: window.cfg
                disks: window.disks

                onNext: window.go(hostnameComponent)
                onBack: window.go(networkComponent)
            }
        }

        Component {
            id: hostnameComponent

            Installer.Hostname {
                cfg: window.cfg

                onNext: window.go(usernameComponent)
            }
        }

        Component {
            id: usernameComponent

            Installer.Username {
                cfg: window.cfg

                onNext: window.go(gitNameComponent)
            }
        }

        Component {
            id: gitNameComponent

            Installer.GitName {
                cfg: window.cfg

                onNext: window.go(gitEmailComponent)
                onBack: window.go(usernameComponent)
            }
        }

        Component {
            id: gitEmailComponent

            Installer.GitEmail {
                cfg: window.cfg

                onNext: window.go(aiComponent)
                onBack: window.go(gitNameComponent)
            }
        }

        Component {
            id: aiComponent

            Installer.Ai {
                cfg: window.cfg

                onNext: window.go(userPasswordComponent)
                onBack: window.go(gitEmailComponent)
            }
        }

        Component {
            id: userPasswordComponent

            Installer.UserPassword {
                wizard: window.wizard

                onNext: window.go(userPasswordConfirmComponent)
            }
        }

        Component {
            id: userPasswordConfirmComponent

            Installer.UserPasswordConfirm {
                cfg: window.cfg
                wizard: window.wizard

                onNext: window.go(confirmComponent)
                onMismatch: window.go(userPasswordComponent, {
                        error: "passwords do not match, try again"
                    })
            }
        }

        Component {
            id: confirmComponent

            Installer.Confirm {
                cfg: window.cfg

                onConfirmed: window.go(doneComponent)
                onBack: window.go(window.afterNetworkComponent())
            }
        }

        Component {
            id: doneComponent

            Installer.Done {
                onQuit: Qt.quit()
            }
        }

        Component {
            id: failedComponent

            Installer.Failed {
                onQuit: Qt.quit()
            }
        }

        // --- hardware detection: main.rs's swap_size_from_meminfo() + -----
        // --- list_disks() + autodetect_disk(), run once at startup -------

        Process {
            id: meminfoProc

            command: ["cat", "/proc/meminfo"]

            stdout: StdioCollector {
                onStreamFinished: {
                    window.cfg.swapSizeGib = Config.swapSizeGibFromMeminfo(this.text);
                    lsblkProc.running = true;
                }
            }
        }

        Process {
            id: lsblkProc

            command: ["lsblk", "-J", "-b", "-d", "-o", "NAME,PATH,SIZE,MODEL,RM,TYPE,RO"]

            stdout: StdioCollector {
                onStreamFinished: {
                    try {
                        window.disks = Disks.parseLsblk(this.text);
                        findmntProc.running = true;
                    } catch (e) {
                        window.disks = [];
                        window.finishDiskDetection();
                    }
                }
            }
        }

        // Excludes the live medium disko.nix must never be offered to erase
        // — disks.rs::live_medium_disk. `findmnt` names the device /iso is
        // mounted from; a missing /iso (e.g. this dev sandbox) just skips
        // the exclusion; the pipeline still finishes either way.
        Process {
            id: findmntProc

            command: ["findmnt", "-rn", "-o", "SOURCE", "/iso"]

            stdout: StdioCollector {
                onStreamFinished: {
                    const src = this.text.trim();
                    if (src.startsWith("/dev/")) {
                        pknameProc.liveSource = src;
                        pknameProc.command = ["lsblk", "-no", "PKNAME", src];
                        pknameProc.running = true;
                    } else {
                        window.finishDiskDetection();
                    }
                }
            }

            // qmllint disable signal-handler-parameters
            onExited: exitCode => {
                if (exitCode !== 0)
                    window.finishDiskDetection();
            }
            // qmllint enable signal-handler-parameters
        }

        Process {
            id: pknameProc

            property string liveSource: ""

            stdout: StdioCollector {
                onStreamFinished: {
                    const parent = this.text.trim();
                    const live = parent.length > 0 ? `/dev/${parent}` : Disks.parentDisk(pknameProc.liveSource);
                    window.disks = window.disks.filter(d => d.path !== live);
                    window.finishDiskDetection();
                }
            }
        }

        function finishDiskDetection() {
            try {
                const picked = Disks.autodetectDisk(window.disks, window.cfg.swapSizeGib);
                window.cfg.disks = [picked.path];
                window.diskAuto = true;
            } catch (e) {
                window.diskAuto = false;
            }
            window.disksReady = true;
        }

        // Proof for the LiveISO smoke test that a Quickshell window actually
        // came up under cage, not just that the process started: fired from
        // Component.onCompleted (Qt has built the window by then), not from
        // the systemd unit's old ExecStartPre, which ran before qs was even
        // exec'd and so proved nothing about the shell itself. /bin/sh is
        // hardcoded rather than a bare `sh` because this process inherits
        // whatever PATH the cage session happens to have, and NixOS
        // guarantees /bin/sh unconditionally; echo's shell-builtin redirects
        // need no other binary resolved through it. Both sinks are written:
        // /dev/ttyS0 is the serial line the VM smoke test reads
        // (wait_for_console_text), /dev/console is what a real install would
        // show on the local head.
        Process {
            id: readyMarker

            command: ["/bin/sh", "-c", "echo DOTS_UI_READY > /dev/ttyS0 2>/dev/null; echo DOTS_UI_READY > /dev/console 2>/dev/null; true"]
        }
    }
}
