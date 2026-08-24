//! The numbers a notification carries to the daemon.

use dots_osd::model::{Linger, Notification, Urgency};

#[test]
fn each_lifetime_resolves_to_the_timeout_it_promises() {
    // These milliseconds are load-bearing rather than decorative. dots-osd
    // sends them as `expire_timeout` precisely so it does not depend on a
    // dunstrc rule that Home Manager would render ahead of the urgency
    // sections overriding it, which means nothing downstream would catch a
    // typo here. Every other test only checks which variant was chosen.
    assert_eq!(Linger::Brief.milliseconds(), 2_000);
    assert_eq!(Linger::Normal.milliseconds(), 8_000);
    assert_eq!(Linger::Long.milliseconds(), 15_000);
}

#[test]
fn lifetimes_are_ordered_the_way_they_read() {
    assert!(Linger::Brief.milliseconds() < Linger::Normal.milliseconds());
    assert!(Linger::Normal.milliseconds() < Linger::Long.milliseconds());
}

#[test]
fn urgency_hints_match_the_freedesktop_numbering() {
    // dunst keys its urgency_low/normal/critical sections on these exact
    // values, so they are a wire format rather than an internal choice.
    assert_eq!(Urgency::Low.hint(), 0);
    assert_eq!(Urgency::Normal.hint(), 1);
    assert_eq!(Urgency::Critical.hint(), 2);
}

#[test]
fn a_new_notification_is_normal_and_ordinary_length() {
    let notification = Notification::new("tag", "icon", "Summary");
    assert_eq!(notification.urgency, Urgency::Normal);
    assert_eq!(notification.linger, Linger::Normal);
    assert_eq!(notification.value, None);
    assert!(notification.body.is_empty());
}

#[test]
fn a_boosted_volume_fills_the_bar_without_overflowing_it() {
    // A sink pushed past unity gain reads above 100. The bar tops out while
    // the number in the body keeps telling the truth.
    assert_eq!(Notification::new("t", "i", "s").value(150).value, Some(100));
    assert_eq!(Notification::new("t", "i", "s").value(100).value, Some(100));
    assert_eq!(Notification::new("t", "i", "s").value(0).value, Some(0));
    assert_eq!(Notification::new("t", "i", "s").value(37).value, Some(37));
}
