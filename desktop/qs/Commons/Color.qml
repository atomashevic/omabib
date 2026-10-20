pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// The Omarchy shell's Color, as far as Omabib uses it: the active Omarchy
// theme's foundational palette, read from its colors.toml the way the shell
// reads it. omarchyTheme says whether there is one to follow; the shell's own
// Color has no such property, since under the shell there always is.
//
// mode is "light" or "dark" when the file says so, and "" when it does not.
// A file that does not parse leaves the previous palette where it is. The
// watch follows an in-place write and a replaced theme directory.
QtObject {
    id: root

    property bool omarchyTheme: false
    // Bumps on every read, including one that keeps the previous palette.
    property int revision: 0
    property string mode: ""
    property color background: "#101315"
    property color foreground: "#cacccc"
    property color accent: "#cacccc"
    property color urgent: "#a55555"
    property color muted: "#707880"

    function load(raw) {
        revision += 1
        const values = {}
        let named = ""
        for (const line of String(raw || "").split("\n")) {
            const match = line.match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
            if (match) values[match[1]] = match[2]
            const modeLine = line.match(/^\s*mode\s*=\s*["']?([A-Za-z]+)["']?/)
            if (modeLine) named = modeLine[1] === "light" || modeLine[1] === "dark" ? modeLine[1] : ""
        }
        const pick = (...keys) => keys.map(k => values[k]).find(v => v !== undefined)
        const bg = pick("background", "color0")
        const fg = pick("foreground", "color7")
        if (!bg || !fg) return
        background = bg
        foreground = fg
        accent = pick("accent", "color4") || fg
        urgent = pick("red", "color1") || urgent
        muted = pick("muted", "color8") || fg
        mode = named
        omarchyTheme = true
    }

    property FileView colors: FileView {
        path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
        watch: true
        onLoaded: root.load(text())
        onLoadFailed: { root.revision += 1; root.omarchyTheme = false }
    }
}
