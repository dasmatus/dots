//! Session and power commands.
//!
//! This is what `HyprTile`'s page 2 was: lock, logout, suspend, hibernate,
//! reboot, shutdown. Logout goes through `hyprctl dispatch exit`, which ends
//! the compositor and so ends the session, the same effect the old
//! loginctl-terminate-session entry had.
//!
//! Screenshot and screen recording live here too, because removing `HyprTile`
//! also removed `hyprtile-shotter` and `hyprtile-screener`.

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

pub struct System;

/// Command id, label, subtitle, shell command.
const COMMANDS: &[(&str, &str, &str, &str)] = &[
    (
        "lock",
        "Lock Screen",
        "Lock the session with hyprlock",
        "hyprlock",
    ),
    (
        "logout",
        "Log Out",
        "End the Hyprland session",
        "hyprctl dispatch exit",
    ),
    ("suspend", "Suspend", "Suspend to RAM", "systemctl suspend"),
    (
        "hibernate",
        "Hibernate",
        "Suspend to disk",
        "systemctl hibernate",
    ),
    (
        "reboot",
        "Restart",
        "Reboot the machine",
        "systemctl reboot",
    ),
    (
        "shutdown",
        "Shut Down",
        "Power off the machine",
        "systemctl poweroff",
    ),
    (
        "screenshot",
        "Screenshot Screen",
        "Capture the focused output",
        "hyprshot -m output",
    ),
    (
        "screenshot-region",
        "Screenshot Region",
        "Select a region to capture",
        "hyprshot -m region",
    ),
    (
        "record",
        "Toggle Screen Recording",
        "Start or stop wl-screenrec",
        "beamenu-record toggle",
    ),
];

impl Provider for System {
    fn id(&self) -> &'static str {
        "system"
    }

    fn section(&self) -> &'static str {
        "System"
    }

    fn query(&self, _ctx: &Ctx, _query: &str) -> Vec<Item> {
        COMMANDS
            .iter()
            .map(|(id, label, subtitle, command)| {
                Item::new(
                    format!("system:{id}"),
                    *label,
                    Action::Shell((*command).to_string()),
                )
                .subtitle(*subtitle)
                .accessory("Command")
            })
            .collect()
    }
}

/// Command ids this provider exposes, for `beamenu --command <id>`.
#[must_use]
pub fn command_ids() -> Vec<&'static str> {
    COMMANDS.iter().map(|(id, ..)| *id).collect()
}

/// The shell command behind a `--command` id.
#[must_use]
pub fn command_for(id: &str) -> Option<&'static str> {
    COMMANDS
        .iter()
        .find(|(cid, ..)| *cid == id)
        .map(|(.., command)| *command)
}
