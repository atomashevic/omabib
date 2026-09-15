pragma Singleton
import QtQuick

// Offscreen stand-in for the shell's palette, with the City 783 values the
// shell resolves on the development desktop.
QtObject {
    property color background: "#181a1f"
    property color foreground: "#b9bec6"
    property color accent: "#ad2222"
    property color urgent: "#e53939"
    property color muted: "#4b515b"
    readonly property QtObject menu: QtObject {
        property color background: "#20232a"
        property color text: "#b9bec6"
        property color border: "#ad2222"
        property color scrim: Qt.rgba(0.063, 0.071, 0.086, 0.62)
        property color selectedBackground: "#2b2f37"
        property color selectedText: "#eceff2"
    }
    readonly property QtObject tooltip: QtObject {
        property color background: "#20232a"
        property color text: "#b9bec6"
        property color border: "#ad2222"
    }
}
