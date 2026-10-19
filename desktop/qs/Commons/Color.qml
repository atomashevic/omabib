pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The Omarchy shell's Color, as far as Omabib uses it: the active Omarchy
// theme's foundational palette, read from its colors.toml the way the shell
// reads it. omarchyTheme says whether there is one to follow; the shell's own
// Color has no such property, since under the shell there always is.
QtObject {
    id: root

    property bool omarchyTheme: false
    property color background: "#101315"
    property color foreground: "#cacccc"
    property color accent: "#cacccc"
    property color urgent: "#a55555"
    property color muted: "#707880"

    function load(raw) {
        const values = {}
        for (const line of String(raw || "").split("\n")) {
            const match = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
            if (match) values[match[1]] = match[2]
        }
        const pick = (...keys) => keys.map(k => values[k]).find(v => v !== undefined)
        const bg = pick("background", "color0")
        const fg = pick("foreground", "color7")
        if (!bg || !fg) { omarchyTheme = false; return }
        background = bg
        foreground = fg
        accent = pick("accent", "color4") || fg
        urgent = pick("red", "color1") || urgent
        muted = pick("muted", "color8") || fg
        omarchyTheme = true
    }

    property FileView colors: FileView {
        path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
        onLoaded: root.load(text())
        onLoadFailed: root.omarchyTheme = false
    }
}
