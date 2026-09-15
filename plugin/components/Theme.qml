import QtQuick
import qs.Commons

// Every color, font and size the popup draws with, resolved from the shell's
// qs.Commons tokens so each Omarchy theme restyles it. One instance lives in
// App.qml and is handed to each component.
QtObject {
    id: theme

    // Proportional family for long-form reading: titles, abstracts, notes and
    // the AI overview. App.qml sets it from OMABIB_READING_FONT.
    property string readingFamily: "Noto Sans"

    readonly property string mono: Style.font.menuFamily
    // The shell's own alias; it resolves to the Nerd Font that carries the
    // Material Design glyphs Icons.js names.
    readonly property string iconFamily: Style.font.family

    readonly property color card: Color.menu.background
    readonly property color app: Color.background
    readonly property color text: Color.menu.text
    readonly property color bright: Color.menu.selectedText
    readonly property color muted: Qt.rgba(text.r, text.g, text.b, 0.74)
    readonly property color dim: Qt.rgba(text.r, text.g, text.b, 0.52)
    // Hairlines between panes and the selected-row fill.
    readonly property color line: Color.menu.selectedBackground
    readonly property color border: Color.menu.border
    readonly property color accent: Color.accent
    readonly property bool light: (card.r * 0.299 + card.g * 0.587 + card.b * 0.114) > 0.55
    // Accent colors are authored for fills; text on the card needs more
    // contrast in either direction.
    readonly property color accentText: light ? Qt.darker(accent, 1.25) : Qt.lighter(accent, 1.5)
    readonly property color urgent: Color.urgent
    readonly property color scrim: Color.menu.scrim

    readonly property color controlBorder: Style.normalBorderColor
    readonly property color hoverFill: Style.hoverFill
    readonly property color selectedFill: Style.selectedFill
    readonly property color pressedFill: Style.pressedFill
    readonly property color focusFill: Style.focusFillColor
    readonly property color focusBorder: Style.focusBorderColor
    readonly property int focusBorderWidth: Math.max(1, Style.focusBorderWidth)
    readonly property real radius: Style.cornerRadius

    readonly property int caption: Style.font.caption
    readonly property int small: Style.font.bodySmall
    readonly property int body: Style.font.body
    readonly property int subtitle: Style.font.subtitle
    readonly property int title: Style.font.title
    readonly property int heading: Style.font.heading
    readonly property int display: Style.font.display

    function space(px) { return Style.space(px) }
    // An opaque #rrggbb for rich-text CSS, blending a translucent color over the card.
    function css(c) {
        var a = c.a
        return Qt.rgba(c.r * a + card.r * (1 - a), c.g * a + card.g * (1 - a), c.b * a + card.b * (1 - a), 1).toString()
    }
}
