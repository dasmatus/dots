//! Window switching and management, reached with a leading `w `.
//!
//! Hyprland's IPC is already spoken elsewhere in this repo (rust/hyprmon), and
//! the same shape works here: `hyprctl -j clients` for the list, `hyprctl
//! dispatch` for the actions. Shelling out rather than opening the socket
//! keeps this provider a pure string transformation, which is what makes it
//! testable without a compositor.

use serde::Deserialize;

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider, Trigger};

pub struct Windows;

#[derive(Debug, Clone, Deserialize)]
pub struct Client {
    pub address: String,
    #[serde(default)]
    pub class: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub workspace: Workspace,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Workspace {
    #[serde(default)]
    pub name: String,
}

/// Parse `hyprctl -j clients` output.
///
/// Windows with an empty title are dropped: Hyprland reports transient
/// surfaces and some layer shells that way, and they are not switchable
/// targets.
#[must_use]
pub fn parse_clients(json: &str) -> Vec<Client> {
    serde_json::from_str::<Vec<Client>>(json)
        .unwrap_or_default()
        .into_iter()
        .filter(|c| !c.title.trim().is_empty())
        .collect()
}

/// Window-management commands offered alongside the switcher.
const ACTIONS: &[(&str, &str, &str)] = &[
    (
        "fullscreen",
        "Toggle Fullscreen",
        "hyprctl dispatch fullscreen 0",
    ),
    (
        "float",
        "Toggle Floating",
        "hyprctl dispatch togglefloating",
    ),
    ("center", "Center Window", "hyprctl dispatch centerwindow"),
    ("close", "Close Window", "hyprctl dispatch killactive"),
    ("left", "Move Left", "hyprctl dispatch movewindow l"),
    ("right", "Move Right", "hyprctl dispatch movewindow r"),
    ("up", "Move Up", "hyprctl dispatch movewindow u"),
    ("down", "Move Down", "hyprctl dispatch movewindow d"),
];

fn clients() -> Vec<Client> {
    std::process::Command::new("hyprctl")
        .args(["-j", "clients"])
        .output()
        .ok()
        .map(|out| parse_clients(&String::from_utf8_lossy(&out.stdout)))
        .unwrap_or_default()
}

impl Provider for Windows {
    fn id(&self) -> &'static str {
        "window"
    }

    fn section(&self) -> &'static str {
        "Windows"
    }

    fn trigger(&self) -> Trigger {
        Trigger::Prefix("w ")
    }

    fn query(&self, _ctx: &Ctx, _query: &str) -> Vec<Item> {
        let mut items: Vec<Item> = clients()
            .into_iter()
            .map(|client| {
                Item::new(
                    format!("window:{}", client.address),
                    client.title.clone(),
                    Action::FocusWindow(client.address.clone()),
                )
                .subtitle(client.class.clone())
                .accessory(format!("Workspace {}", client.workspace.name))
                .alt(
                    "Close",
                    Action::Shell(format!(
                        "hyprctl dispatch closewindow address:{}",
                        client.address
                    )),
                )
            })
            .collect();

        items.extend(ACTIONS.iter().map(|(id, label, command)| {
            Item::new(
                format!("window:{id}"),
                *label,
                Action::Shell((*command).to_string()),
            )
            .accessory("Window")
            .section("Window Management")
        }));

        items
    }
}
