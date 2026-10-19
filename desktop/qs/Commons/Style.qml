pragma Singleton
import QtQuick

// The shell's structural tokens: fills, borders, radius and the type scale.
QtObject {
    readonly property color ink: Color.menu.text
    readonly property color strong: Color.menu.selectedText

    readonly property real cornerRadius: 6
    readonly property color normalBorderColor: Qt.rgba(ink.r, ink.g, ink.b, 0.32)
    readonly property color hoverFill: Qt.rgba(ink.r, ink.g, ink.b, 0.08)
    readonly property color selectedFill: Qt.rgba(strong.r, strong.g, strong.b, 0.14)
    readonly property color pressedFill: Qt.rgba(ink.r, ink.g, ink.b, 0.2)
    readonly property color focusFillColor: Qt.rgba(strong.r, strong.g, strong.b, 0.08)
    readonly property color focusBorderColor: Color.accent
    readonly property int focusBorderWidth: 2
    readonly property int normalBorderWidth: 1
    readonly property QtObject font: QtObject {
        // Icons.js names Material Design glyphs, which the Nerd Font carries.
        readonly property string family: "JetBrainsMono Nerd Font"
        readonly property string menuFamily: "JetBrainsMono Nerd Font"
        readonly property int caption: 10
        readonly property int bodySmall: 11
        readonly property int body: 12
        readonly property int subtitle: 13
        readonly property int title: 14
        readonly property int heading: 16
        readonly property int display: 24
        readonly property int icon: 14
    }
    function space(px) { var n = Number(px); return n <= 0 ? 0 : Math.max(1, Math.round(n)) }
}
