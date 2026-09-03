// Pins common/EdgeStrip.qml's two supported edges against a sized parent.
// EdgeStrip only reaches QtQuick and the Theme singleton, so qmltestrunner
// can instantiate it directly through fixtures/theme-stub/ the same way
// tst_chrome_geometry.qml drives Chrome.qml — see tests/README.md for why
// the real generated Theme.qml is off-limits here.
//
// Each host below is a fixed-size Item wrapping one EdgeStrip, with an
// alias exposing the strip itself: the strip anchors to its parent, so its
// width/height can only be read once it actually has one to fill.
import QtQuick
import QtTest
import "fixtures/theme-stub"
import "fixtures/theme-stub/common"

TestCase {
    id: testCase
    name: "EdgeStrip"

    Component {
        id: leftEdge
        Item {
            width: 100
            height: 50
            property alias strip: strip
            EdgeStrip {
                id: strip
                edge: "left"
                active: true
            }
        }
    }

    Component {
        id: topEdge
        Item {
            width: 100
            height: 50
            property alias strip: strip
            EdgeStrip {
                id: strip
                edge: "top"
                active: true
            }
        }
    }

    Component {
        id: inactiveEdge
        Item {
            width: 100
            height: 50
            property alias strip: strip
            EdgeStrip {
                id: strip
                edge: "left"
                active: false
            }
        }
    }

    function test_left_edge_takes_thickness_and_fills_the_parents_height() {
        const host = createTemporaryObject(leftEdge, testCase);
        verify(host !== null);
        compare(host.strip.width, host.strip.thickness);
        compare(host.strip.height, 50);
    }

    function test_top_edge_takes_thickness_and_fills_the_parents_width() {
        const host = createTemporaryObject(topEdge, testCase);
        verify(host !== null);
        compare(host.strip.height, host.strip.thickness);
        compare(host.strip.width, 100);
    }

    function test_active_false_is_not_visible() {
        const host = createTemporaryObject(inactiveEdge, testCase);
        verify(host !== null);
        compare(host.strip.visible, false);
    }

    function test_default_thickness_is_the_shared_theme_token() {
        const host = createTemporaryObject(leftEdge, testCase);
        verify(host !== null);
        compare(host.strip.thickness, Theme.chromeStripWidth);
    }
}
