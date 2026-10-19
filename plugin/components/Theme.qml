import QtQuick
import qs.Commons

// Every color, font and size the window draws with. One instance lives in
// App.qml and is handed to each component.
//
// Light and Dark are Omabib's own palettes: GitHub's neutrals and accent blue
// with macOS spacing. Omarchy derives the same roles from the active Omarchy
// theme (qs.Commons Color). Sizes scale with the shell's text size.
QtObject {
    id: theme

    // "system", "light", "dark" or "omarchy" (settings.theme).
    property string mode: "system"
    // "sans" or "serif" for paper titles, abstracts and notes (settings.reading_font).
    property string reading: "sans"

    // The shell's Color always reflects Omarchy; the standalone app's says
    // whether it found an Omarchy theme to follow.
    readonly property bool omarchyAvailable: Color.omarchyTheme !== false
    readonly property bool systemDark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property string resolved: mode === "omarchy" && omarchyAvailable ? "omarchy"
        : mode === "light" || mode === "dark" ? mode
        : systemDark ? "dark" : "light"

    readonly property var lightPalette: ({
        bg: "#ffffff", side: "#f6f8fa", raised: "#ffffff", hover: "#eef1f4", pressed: "#e3e8ee",
        line: "#d1d9e0", text: "#1f2328", bright: "#0f1317", muted: "#59636e", subtle: "#6e7781",
        accent: "#0969da", accentText: "#0969da", accentFill: "#0969da", onAccent: "#ffffff",
        sel: Qt.rgba(9 / 255, 105 / 255, 218 / 255, 0.10), success: "#1a7f37", warn: "#9a6700", danger: "#d1242f",
        scrim: Qt.rgba(31 / 255, 35 / 255, 40 / 255, 0.28), canvas: "#eaeef2", page: "#ffffff", ink: "#1f2328", dark: false
    })
    readonly property var darkPalette: ({
        bg: "#0f1115", side: "#15181d", raised: "#1b1f25", hover: "#1f242b", pressed: "#262c34",
        line: "#2c323a", text: "#e6e9ee", bright: "#f5f7fa", muted: "#9aa2ad", subtle: "#7d8590",
        accent: "#4c9bff", accentText: "#6cb0ff", accentFill: "#1f6feb", onAccent: "#ffffff",
        sel: Qt.rgba(76 / 255, 155 / 255, 1, 0.14), success: "#3fb950", warn: "#d29922", danger: "#f85149",
        scrim: Qt.rgba(1 / 255, 4 / 255, 9 / 255, 0.55), canvas: "#0a0c0f", page: "#171a20", ink: "#d5dae1", dark: true
    })
    readonly property var omarchyPalette: {
        const bg = Color.background, fg = Color.foreground, ac = Color.accent
        const dark = luminance(bg) < 0.5
        return {
            bg: bg, side: mix(bg, fg, 0.035), raised: dark ? mix(bg, fg, 0.06) : bg,
            hover: mix(bg, fg, 0.07), pressed: mix(bg, fg, 0.12), line: mix(bg, fg, dark ? 0.16 : 0.18),
            text: fg, bright: fg, muted: mix(fg, bg, 0.3), subtle: mix(fg, bg, 0.45),
            accent: ac, accentText: dark ? Qt.lighter(ac, 1.15) : Qt.darker(ac, 1.2), accentFill: ac,
            onAccent: luminance(ac) > 0.55 ? "#111111" : "#ffffff", sel: Qt.rgba(ac.r, ac.g, ac.b, 0.16),
            success: dark ? "#3fb950" : "#1a7f37", warn: dark ? "#d29922" : "#9a6700", danger: Color.urgent,
            scrim: Qt.rgba(bg.r, bg.g, bg.b, 0.6), canvas: mix(bg, dark ? "#000000" : fg, dark ? 0.35 : 0.06),
            page: mix(bg, fg, 0.04), ink: fg, dark: dark
        }
    }
    readonly property var p: resolved === "omarchy" ? omarchyPalette : resolved === "dark" ? darkPalette : lightPalette

    // Fonts, bundled and loaded by App.qml, except the platform's own monospace.
    readonly property string sans: "Mona Sans"
    readonly property string serif: "Source Serif 4"
    readonly property string mono: Qt.platform.os === "osx" ? "Menlo" : "monospace"
    readonly property string iconFamily: "lucide"
    readonly property string readingFamily: reading === "serif" ? serif : sans

    // Surfaces: the window and its panes, the sidebar and fields, popovers and dialogs.
    readonly property color app: p.bg
    readonly property color card: p.bg
    readonly property color side: p.side
    readonly property color raised: p.raised
    readonly property color canvas: p.canvas
    readonly property color text: p.text
    readonly property color bright: p.bright
    readonly property color muted: p.muted
    readonly property color dim: p.subtle
    readonly property color line: p.line
    readonly property color border: p.line
    readonly property color accent: p.accent
    readonly property color accentText: p.accentText
    readonly property color accentFill: p.accentFill
    readonly property color onAccent: p.onAccent
    readonly property color success: p.success
    readonly property color warn: p.warn
    readonly property color urgent: p.danger
    readonly property bool light: !p.dark
    // PDF pages in theme colors: the paper and the ink.
    readonly property color pageBackground: p.page
    readonly property color pageText: p.ink
    readonly property color scrim: p.scrim

    readonly property color controlBorder: p.line
    readonly property color hoverFill: p.hover
    readonly property color selectedFill: p.sel
    readonly property color pressedFill: p.pressed
    readonly property color focusFill: { const a = Qt.color(p.accent); return Qt.rgba(a.r, a.g, a.b, 0.08) }
    readonly property color focusBorder: p.accent
    readonly property int focusBorderWidth: 2
    readonly property real radius: space(8)
    readonly property real radiusSmall: space(6)
    readonly property real radiusLarge: space(12)

    // The type scale; the shell's text size setting scales it.
    readonly property real scale: Style.space(100) / 100
    readonly property int caption: Math.round(11 * scale)
    readonly property int small: Math.round(12 * scale)
    readonly property int body: Math.round(13 * scale)
    readonly property int subtitle: Math.round(14 * scale)
    readonly property int title: Math.round(15 * scale)
    readonly property int heading: Math.round(22 * scale)
    readonly property int display: Math.round(28 * scale)

    function space(px) { return Style.space(px) }
    // Shortcuts as the platform writes them. On macOS Qt takes Ctrl in a
    // shortcut to mean Command, so Ctrl+K is ⌘K.
    function keys(text) {
        if (Qt.platform.os !== "osx" || !text) return text
        return String(text).replace(/Ctrl\+/g, "⌘").replace(/Alt\+/g, "⌥").replace(/Shift\+/g, "⇧")
    }
    function mix(a, b, t) {
        const x = Qt.color(a), y = Qt.color(b)
        return Qt.rgba(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t, 1)
    }
    function luminance(c) {
        const x = Qt.color(c)
        return x.r * 0.299 + x.g * 0.587 + x.b * 0.114
    }
    // Colors and sizes for Markdown.toHtml, with code blocks on `codeBackground`.
    function markdownStyle(codeBackground) {
        return {
            reading: readingFamily, mono: mono, size: reading === "serif" ? subtitle + 1 : subtitle, heading: heading, small: small,
            text: css(text), bright: css(bright), muted: css(muted), dim: css(dim), line: css(line),
            codeBg: css(codeBackground), link: css(accentText), urgent: css(urgent)
        }
    }
    // An opaque #rrggbb for rich-text CSS, blending a translucent color over the pane.
    function css(c) {
        const a = c.a
        return Qt.rgba(c.r * a + card.r * (1 - a), c.g * a + card.g * (1 - a), c.b * a + card.b * (1 - a), 1).toString()
    }
}
