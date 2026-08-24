//! The things a keybind does, each returning the notification that says it
//! happened.
//!
//! Actuating and announcing belong together. The watcher notices the world
//! changing every few seconds, which is right for a VPN dropping and useless
//! for a volume key: nobody presses a key and waits five seconds to learn
//! whether it worked. So the keybind calls in here, the change and the read-back
//! happen in one process, and the notification carries the value that actually
//! resulted rather than the one that was asked for.
//!
//! The read-back is not free, and the asymmetry between the two is why they are
//! read back differently. `wpctl` connects to `PipeWire` on every run, so a
//! volume keypress pays for two of them; `brightnessctl` only writes sysfs, and
//! the level is read back out of `/sys` directly rather than by running it
//! again.
//!
//! Measured end to end with hyperfine (release build, 30 runs), against the
//! bare commands these replace:
//!
//! | command                 | this      | what it replaces |
//! |-------------------------|-----------|------------------|
//! | `dots-osd volume up`    | 32.3 ms   | 20.0 ms          |
//! | `dots-osd brightness up`|  7.0 ms   |  3.2 ms          |
//!
//! So the OSD costs about twelve milliseconds on the volume path and four on
//! the brightness one. Both stay well inside the tenth of a second at which
//! feedback stops feeling immediate, which is the budget that matters here.
//! The volume keys repeat while held, so that is the number to watch if
//! anything is ever added to this path.

use std::path::PathBuf;
use std::process::Command;

use beamenu_status::model::Volume;
use beamenu_status::probe;
use serde::Deserialize;

use crate::error::{Error, Result};
use crate::model::{Notification, Urgency};
use crate::observe;

/// How far one keypress moves a level.
///
/// Five percent, matching the binds this replaces (`nix/home/hyprland.nix`).
const STEP: &str = "5%";

/// Ceiling for software boost, as `wpctl` spells it.
///
/// The sink can be pushed past unity gain; 1.5 is where the old bind stopped,
/// and going further distorts more than it amplifies.
const VOLUME_LIMIT: &str = "1.5";

/// Which way a level is moving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Up,
    Down,
}

impl Step {
    /// The suffix `wpctl` and `brightnessctl` both use for a relative move.
    const fn sign(self) -> &'static str {
        match self {
            Self::Up => "+",
            Self::Down => "-",
        }
    }
}

/// What a toggle was asked to become.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Switch {
    On,
    Off,
    Toggle,
}

impl Switch {
    /// What this switch means, given where the thing currently is.
    ///
    /// `On` and `Off` ignore `current` on purpose. They are the way out of a
    /// state file that has drifted from reality, so they have to mean what they
    /// say rather than what was last recorded.
    #[must_use]
    pub const fn resolve(self, current: bool) -> bool {
        match self {
            Self::On => true,
            Self::Off => false,
            Self::Toggle => !current,
        }
    }
}

/// Move the default sink and report where it landed.
///
/// # Errors
/// Fails when `wpctl` is missing or refuses the change.
pub fn volume(step: Step) -> Result<Notification> {
    let amount = format!("{STEP}{}", step.sign());
    match step {
        // The limit only binds going up; passing it on the way down would be
        // noise, and `wpctl` floors at zero by itself.
        Step::Up => run(
            "wpctl",
            &[
                "set-volume",
                "-l",
                VOLUME_LIMIT,
                probe::DEFAULT_SINK,
                &amount,
            ],
        )?,
        Step::Down => run("wpctl", &["set-volume", probe::DEFAULT_SINK, &amount])?,
    };
    Ok(sink_notification(read(probe::DEFAULT_SINK)?))
}

/// Toggle the default sink's mute and report the result.
///
/// # Errors
/// Fails when `wpctl` is missing or refuses the change.
pub fn volume_mute() -> Result<Notification> {
    run("wpctl", &["set-mute", probe::DEFAULT_SINK, "toggle"])?;
    Ok(sink_notification(read(probe::DEFAULT_SINK)?))
}

/// Toggle the default source's mute and report the result.
///
/// # Errors
/// Fails when `wpctl` is missing or refuses the change.
pub fn microphone_mute() -> Result<Notification> {
    run("wpctl", &["set-mute", probe::DEFAULT_SOURCE, "toggle"])?;
    let volume = read(probe::DEFAULT_SOURCE)?;
    let (icon, body) = if volume.muted {
        ("microphone-sensitivity-muted-symbolic", "Muted".to_string())
    } else {
        (
            "microphone-sensitivity-high-symbolic",
            format!("Live at {}%", volume.percent),
        )
    };
    Ok(Notification::new("microphone", icon, "Microphone")
        .body(body)
        .urgency(Urgency::Low)
        .brief())
}

/// Move the panel brightness and report where it landed.
///
/// # Errors
/// Fails when `brightnessctl` is missing, or when no backlight is exposed to
/// read the result back from.
pub fn brightness(step: Step) -> Result<Notification> {
    run("brightnessctl", &["set", &format!("{STEP}{}", step.sign())])?;
    let backlight = probe::backlight().ok_or_else(|| Error::Unreadable {
        what: "the panel backlight".to_string(),
    })?;
    // One icon at every level, unlike volume: Adwaita ships a single
    // `display-brightness-symbolic` and no low/medium/high variants, and a name
    // that resolves to nothing would leave the notification with no icon at all
    // rather than with an approximate one.
    Ok(
        Notification::new("brightness", "display-brightness-symbolic", "Brightness")
            .body(format!("{}%", backlight.percent))
            .urgency(Urgency::Low)
            .brief()
            .value(u16::from(backlight.percent)),
    )
}

/// Enable or disable the touchpad, and report which it now is.
///
/// Hyprland exposes no way to *read* a device's enabled flag back, so the
/// answer is kept in the runtime directory instead, which also means it
/// disappears at logout, exactly when Hyprland forgets the setting too.
///
/// # Errors
/// Fails when `hyprctl` is missing, when no touchpad is attached, or when the
/// compositor rejects the change.
pub fn touchpad(switch: Switch) -> Result<Notification> {
    let devices = run("hyprctl", &["devices", "-j"])?;
    let name = touchpad_name(&devices).ok_or(Error::NoTouchpad)?;

    let marker = runtime_path("touchpad")?;
    let enabled = switch.resolve(!marker.exists());

    // `hyprctl keyword` is a silent no-op under Hyprland 0.55+'s Lua parser,
    // so the change goes through `eval` and the DSL, the same route hyprmon
    // takes for monitors.
    run(
        "hyprctl",
        &[
            "eval",
            &format!(
                "hl.device({{ name = {}, enabled = {enabled} }})",
                lua_string(&name)
            ),
        ],
    )?;

    if enabled {
        std::fs::remove_file(&marker).ok();
    } else {
        std::fs::write(&marker, "off").map_err(|source| Error::RuntimeState {
            path: marker.display().to_string(),
            source,
        })?;
    }

    let (icon, body) = if enabled {
        ("input-touchpad-symbolic", "Enabled")
    } else {
        ("touchpad-disabled-symbolic", "Disabled")
    };
    Ok(Notification::new("touchpad", icon, "Touchpad")
        .body(body)
        .urgency(Urgency::Low)
        .brief())
}

/// Mute or unmute the microphone as a privacy switch, naming anything on the
/// camera while it is at it.
///
/// Deliberately narrower than the name suggests, and the notification says so.
/// Muting the source is something a session can do for itself; cutting power to
/// a webcam is not, so rather than pretend, this reports which programs
/// currently hold the camera open so that "privacy on" is never mistaken for
/// "the camera is off".
///
/// # Errors
/// Fails when `wpctl` is missing or refuses the change.
pub fn privacy(switch: Switch) -> Result<Notification> {
    let muted = probe::audio(probe::DEFAULT_SOURCE).is_some_and(|volume| volume.muted);
    let target = switch.resolve(muted);
    run(
        "wpctl",
        &[
            "set-mute",
            probe::DEFAULT_SOURCE,
            if target { "1" } else { "0" },
        ],
    )?;

    if !target {
        return Ok(
            Notification::new("privacy", "security-low-symbolic", "Privacy off")
                .body("Microphone is live again")
                .urgency(Urgency::Low)
                .brief(),
        );
    }

    let cameras = observe::cameras();
    let notification = if cameras.is_empty() {
        Notification::new("privacy", "security-high-symbolic", "Privacy on")
            .body("Microphone muted")
            .urgency(Urgency::Low)
            .brief()
    } else {
        let names: Vec<&str> = cameras
            .iter()
            .map(|camera| camera.process.as_str())
            .collect();
        // The one privacy notification that is not brief: being told the
        // switch did not cover the camera is the whole reason to say anything,
        // and it is no use if it has gone by the time you look up.
        Notification::new("privacy", "camera-web-symbolic", "Privacy on")
            .body(format!(
                "Microphone muted — but {} still has the camera",
                names.join(", ")
            ))
            .urgency(Urgency::Critical)
            .long()
    };
    Ok(notification)
}

fn sink_notification(volume: Volume) -> Notification {
    let body = if volume.muted {
        format!("Muted at {}%", volume.percent)
    } else {
        format!("{}%", volume.percent)
    };
    Notification::new("volume", volume_icon(volume), "Volume")
        .body(body)
        .urgency(Urgency::Low)
        .value(volume.percent)
        .brief()
}

/// The icon that matches a level, so the OSD is readable at a glance without
/// reading the number.
fn volume_icon(volume: Volume) -> &'static str {
    if volume.muted || volume.percent == 0 {
        "audio-volume-muted-symbolic"
    } else if volume.percent > 100 {
        "audio-volume-overamplified-symbolic"
    } else if volume.percent < 34 {
        "audio-volume-low-symbolic"
    } else if volume.percent < 67 {
        "audio-volume-medium-symbolic"
    } else {
        "audio-volume-high-symbolic"
    }
}

/// The subset of `hyprctl devices -j` this needs.
#[derive(Debug, Deserialize)]
struct Devices {
    mice: Vec<Device>,
}

#[derive(Debug, Deserialize)]
struct Device {
    name: String,
}

/// The touchpad's device name, as Hyprland spells it.
///
/// Matched on the name rather than hardcoded because it is built from the
/// hardware ids: `elan0524:00-04f3:3215-touchpad` on one machine, something
/// else on the next. Hyprland files touchpads under `mice`, alongside the
/// pointer node the same hardware also exposes, which is why the suffix is what
/// tells them apart.
#[must_use]
pub fn touchpad_name(devices_json: &str) -> Option<String> {
    let devices: Devices = serde_json::from_str(devices_json).ok()?;
    devices
        .mice
        .into_iter()
        .find(|device| {
            let name = device.name.to_ascii_lowercase();
            name.contains("touchpad") || name.contains("trackpad")
        })
        .map(|device| device.name)
}

/// Quote a value as a Lua string literal.
///
/// Device names come from the kernel, so they are not this crate's to trust:
/// an unescaped quote in one would end the literal early and hand the rest to
/// Hyprland's Lua parser as code.
#[must_use]
pub fn lua_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for character in value.chars() {
        match character {
            '\\' => out.push_str(r"\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            _ => out.push(character),
        }
    }
    out.push('"');
    out
}

/// `$XDG_RUNTIME_DIR/dots-osd/<name>`, with the directory created.
fn runtime_path(name: &str) -> Result<PathBuf> {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from)
        .join("dots-osd");
    std::fs::create_dir_all(&base).map_err(|source| Error::RuntimeState {
        path: base.display().to_string(),
        source,
    })?;
    Ok(base.join(name))
}

fn read(target: &str) -> Result<Volume> {
    probe::audio(target).ok_or_else(|| Error::Unreadable {
        what: format!("the volume of {target}"),
    })
}

/// Run a command, failing loudly and with everything the child said.
///
/// Unlike the probes in `beamenu-status`, a missing binary here is not an
/// ordinary outcome: the caller asked for the volume to move, and it did not.
///
/// A child that exits non-zero has already explained itself on stderr, so that
/// text and the exit status both travel into the diagnostic. Reporting "the
/// command failed" and dropping the rest is how a solved problem becomes a
/// mystery in the journal.
fn run(program: &str, args: &[&str]) -> Result<String> {
    tracing::debug!(program, ?args, "running");
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|source| Error::MissingProgram {
            program: program.to_string(),
            source,
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        // stderr first, then stdout. `hyprctl` is the reason for the fallback:
        // it reports its failures on stdout and leaves stderr empty, so taking
        // stderr alone would throw away the only sentence explaining what went
        // wrong.
        let detail = if stderr.is_empty() {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        } else {
            stderr
        };
        return Err(Error::CommandFailed {
            program: program.to_string(),
            status: output.status,
            detail: (!detail.is_empty()).then_some(detail),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}
