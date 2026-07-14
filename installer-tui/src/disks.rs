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
    /// "476.9 GiB" style rendering for the picker.
    pub fn human_size(&self) -> String {
        let gib = self.size_bytes as f64 / (1024.0 * 1024.0 * 1024.0);
        format!("{gib:.1} GiB")
    }
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
        let size_bytes = dev.get("size").map(size_of).unwrap_or(0);
        if size_bytes == 0 {
            continue;
        }
        let path = dev
            .get("path")
            .and_then(|p| p.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| format!("/dev/{name}"));
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

/// Shell out to lsblk and parse.
pub fn list_disks() -> Result<Vec<Disk>> {
    let out = std::process::Command::new("lsblk")
        .args(["-J", "-b", "-d", "-o", "NAME,PATH,SIZE,MODEL,RM,TYPE,RO"])
        .output()?;
    anyhow::ensure!(out.status.success(), "lsblk failed");
    parse_lsblk(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../tests/fixtures/lsblk.json");

    #[test]
    fn keeps_only_writable_physical_disks() {
        let disks = parse_lsblk(FIXTURE).unwrap();
        let paths: Vec<&str> = disks.iter().map(|d| d.path.as_str()).collect();
        // nvme kept; usb stick kept (removable, string "1" rm field);
        // zram/rom/loop and the read-only vda excluded
        assert_eq!(paths, vec!["/dev/nvme0n1", "/dev/sda"]);
    }

    #[test]
    fn parses_model_and_removable_flag() {
        let disks = parse_lsblk(FIXTURE).unwrap();
        assert_eq!(disks[0].model, "Samsung SSD 980");
        assert!(!disks[0].removable);
        assert!(
            disks[1].removable,
            "string \"1\" rm field parses as removable"
        );
    }

    #[test]
    fn human_size_renders_gib() {
        let d = Disk {
            path: "/dev/nvme0n1".into(),
            size_bytes: 512_110_190_592,
            model: String::new(),
            removable: false,
        };
        assert_eq!(d.human_size(), "476.9 GiB");
    }

    #[test]
    fn rejects_garbage_json() {
        assert!(parse_lsblk("not json").is_err());
    }
}
