pragma Singleton
import QtQuick
import Quickshell

// The Omarchy shell's palette, replaced by a light and a dark one that follow
// the system's color scheme. OMABIB_COLOR_SCHEME=light|dark overrides it.
QtObject {
    readonly property string scheme: Quickshell.env("OMABIB_COLOR_SCHEME") || ""
    readonly property bool dark: scheme === "dark" || (scheme !== "light" && Qt.styleHints.colorScheme !== Qt.ColorScheme.Light)

    readonly property color background: dark ? "#16181d" : "#f2f3f5"
    readonly property color foreground: dark ? "#b9bec6" : "#2b2f36"
    readonly property color accent: dark ? "#5b8cff" : "#2f66d6"
    readonly property color urgent: dark ? "#ef5a52" : "#c9302c"
    readonly property color muted: dark ? "#4b515b" : "#9aa0a8"
    readonly property QtObject menu: QtObject {
        readonly property color background: dark ? "#1e2127" : "#ffffff"
        readonly property color text: dark ? "#b9bec6" : "#2b2f36"
        readonly property color border: dark ? "#2f343d" : "#d5d9df"
        readonly property color scrim: dark ? Qt.rgba(0.04, 0.05, 0.06, 0.62) : Qt.rgba(0.1, 0.12, 0.15, 0.32)
        readonly property color selectedBackground: dark ? "#2a2e36" : "#e7eaee"
        readonly property color selectedText: dark ? "#eceff2" : "#0f1217"
    }
    readonly property QtObject tooltip: QtObject {
        readonly property color background: dark ? "#2a2e36" : "#2b2f36"
        readonly property color text: dark ? "#eceff2" : "#f2f3f5"
        readonly property color border: dark ? "#3a404a" : "#2b2f36"
    }
}
