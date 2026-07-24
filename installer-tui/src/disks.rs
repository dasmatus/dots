//! Enumerate installable target disks by parsing `lsblk -J`.

use anyhow::Result;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Disk {
    pub path: String,
    pub size_bytes: u64,
    pub model: String,
    pub removable: bool,
}

impl Disk {
    /// "476.9 GiB" style rendering.
    #[must_use]
    pub fn human_size(&self) -> String {
        let gib = self.size_bytes as f64 / (1024.0 * 1024.0 * 1024.0);
        format!("{gib:.1} GiB")
    }
}

/// Choose one sufficiently large target, preferring the sole fixed disk.
pub fn autodetect_disk(disks: &[Disk], swap_gib: u64) -> Result<Disk> {
    const GIB: u64 = 1024 * 1024 * 1024;
    const ESP_GIB: u64 = 2;
    const ROOT_GIB: u64 = 20;

    let required_gib = ESP_GIB + swap_gib + ROOT_GIB;
    let eligible: Vec<&Disk> = disks
        .iter()
        .filter(|disk| disk.size_bytes >= required_gib.saturating_mul(GIB))
        .collect();
    let fixed: Vec<&Disk> = eligible
        .iter()
        .copied()
        .filter(|disk| !disk.removable)
        .collect();
    let candidates = if fixed.is_empty() { &eligible } else { &fixed };

    anyhow::ensure!(
        !candidates.is_empty(),
        "no installable disk has the required {required_gib} GiB capacity"
    );
    anyhow::ensure!(
        candidates.len() == 1,
        "disk autodetection is ambiguous: {}",
        candidates
            .iter()
            .map(|disk| disk.path.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok((*candidates[0]).clone())
}

/// Parse `lsblk -J -b -d -o NAME,PATH,SIZE,MODEL,RM,TYPE,RO` output.
/// Keeps writable physical disks only: excludes non-"disk" types (rom, loop),
/// read-only devices, and zram.
pub fn parse_lsblk(json: &str) -> Result<Vec<Disk>> {
    let v: serde_json::Value = serde_json::from_str(json)?;
    let devices = v
        .get("blockdevices")
        .and_then(|d| d.as_array())
        .ok_or_else(|| anyhow::anyhow!("lsblk output missing 'blockdevices'"))?;

    let mut disks = Vec::new();
    for dev in devices {
        if dev.get("type").and_then(|t| t.as_str()) != Some("disk") {
            continue;
        }
        let name = dev.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if name.starts_with("zram") || flag(dev.get("ro")) {
            continue;
        }
        let size_bytes = dev.get("size").map_or(0, size_of);
        if size_bytes == 0 {
            continue;
        }
        let path = dev
            .get("path")
            .and_then(|p| p.as_str())
            .map_or_else(|| format!("/dev/{name}"), str::to_string);
        let model = dev
            .get("model")
            .and_then(|m| m.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        disks.push(Disk {
            path,
            size_bytes,
            model,
            removable: flag(dev.get("rm")),
        });
    }
    Ok(disks)
}

/// lsblk emits native booleans (util-linux >= 2.37) or "0"/"1" strings.
fn flag(v: Option<&serde_json::Value>) -> bool {
    match v {
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::String(s)) => s == "1" || s == "true",
        Some(serde_json::Value::Number(n)) => n.as_i64() == Some(1),
        _ => false,
    }
}

fn size_of(v: &serde_json::Value) -> u64 {
    match v {
        serde_json::Value::Number(n) => n.as_u64().unwrap_or(0),
        serde_json::Value::String(s) => s.trim().parse().unwrap_or(0),
        _ => 0,
    }
}

/// Strip a partition suffix: /dev/sda1 → /dev/sda, /dev/nvme0n1p2 → /dev/nvme0n1.
/// Heuristic fallback — `live_medium_disk` prefers lsblk's authoritative PKNAME.
#[must_use]
pub fn parent_disk(path: &str) -> String {
    let stripped = path.trim_end_matches(|c: char| c.is_ascii_digit());
    if stripped.len() == path.len() || stripped == "/dev/" {
        return path.to_string();
    }
    // Digit-named disks (nvme0n1, mmcblk0) use a 'p' separator before the
    // partition number; only a trailing pN may be stripped from them.
    if let Some(pre) = stripped.strip_suffix('p') {
        if pre.ends_with(|c: char| c.is_ascii_digit()) {
            return pre.to_string();
        }
    }
    // A remaining inner digit (nvme0n[1]) means the "suffix" was part of the
    // disk name itself, not a partition number.
    let base = stripped.rsplit('/').next().unwrap_or(stripped);
    if base.chars().any(|c| c.is_ascii_digit()) {
        return path.to_string();
    }
    stripped.to_string()
}

/// The disk backing the running live system (the NixOS ISO mounts its medium
/// at /iso) — offering it in the picker would let the user erase the medium
/// the installer is running from.
fn live_medium_disk() -> Option<String> {
    let out = std::process::Command::new("findmnt")
        .args(["-rn", "-o", "SOURCE", "/iso"])
        .output()
        .ok()?;
    let src = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || !src.starts_with("/dev/") {
        return None;
    }
    // PKNAME is authoritative (empty when src is already a whole disk).
    if let Ok(pk) = std::process::Command::new("lsblk")
        .args(["-no", "PKNAME", &src])
        .output()
    {
        let parent = String::from_utf8_lossy(&pk.stdout).trim().to_string();
        if pk.status.success() && !parent.is_empty() {
            return Some(format!("/dev/{parent}"));
        }
    }
    Some(parent_disk(&src))
}

/// Shell out to lsblk and parse, excluding the live boot medium.
pub fn list_disks() -> Result<Vec<Disk>> {
    let out = std::process::Command::new("lsblk")
        .args(["-J", "-b", "-d", "-o", "NAME,PATH,SIZE,MODEL,RM,TYPE,RO"])
        .output()?;
    anyhow::ensure!(out.status.success(), "lsblk failed");
    let mut disks = parse_lsblk(&String::from_utf8_lossy(&out.stdout))?;
    if let Some(live) = live_medium_disk() {
        disks.retain(|d| d.path != live);
    }
    Ok(disks)
}
