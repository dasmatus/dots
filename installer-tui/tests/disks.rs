//! lsblk parsing + partition-suffix tests.

use dots_installer::disks::{parent_disk, parse_lsblk, Disk};

const FIXTURE: &str = include_str!("fixtures/lsblk.json");

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

#[test]
fn parent_disk_strips_partition_suffixes() {
    assert_eq!(parent_disk("/dev/sda1"), "/dev/sda");
    assert_eq!(parent_disk("/dev/nvme0n1p2"), "/dev/nvme0n1");
    assert_eq!(parent_disk("/dev/mmcblk0p1"), "/dev/mmcblk0");
    assert_eq!(parent_disk("/dev/vda"), "/dev/vda");
    assert_eq!(parent_disk("/dev/nvme0n1"), "/dev/nvme0n1");
}
