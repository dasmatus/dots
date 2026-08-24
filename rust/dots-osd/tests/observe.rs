//! Which open file descriptors count as "something has the camera".

use dots_osd::observe::is_camera_device;

#[test]
fn video_nodes_are_cameras() {
    assert!(is_camera_device("/dev/video0"));
    // A UVC webcam exposes a metadata node beside the capture one, and holding
    // either means the camera is open.
    assert!(is_camera_device("/dev/video1"));
    assert!(is_camera_device("/dev/video42"));
}

#[test]
fn everything_else_is_not() {
    assert!(!is_camera_device("/dev/null"));
    assert!(!is_camera_device("/dev/snd/pcmC0D0c"));
    assert!(!is_camera_device("/home/matus/video0"));
    assert!(!is_camera_device("socket:[12345]"));
    assert!(!is_camera_device(""));
}
