pragma Singleton
import QtQuick

// Offscreen stand-in for the shell's structural tokens (City 783, base 12).
QtObject {
    property real cornerRadius: 0
    readonly property color normalBorderColor: Qt.rgba(0.725, 0.745, 0.776, 0.4)
    readonly property color hoverFill: Qt.rgba(0.725, 0.745, 0.776, 0.08)
    readonly property color selectedFill: Qt.rgba(0.925, 0.937, 0.949, 0.16)
    readonly property color pressedFill: Qt.rgba(0.725, 0.745, 0.776, 0.22)
    readonly property color focusFillColor: Qt.rgba(0.925, 0.937, 0.949, 0.10)
    readonly property color focusBorderColor: "#ad2222"
    readonly property int focusBorderWidth: 2
    readonly property int normalBorderWidth: 1
    readonly property QtObject font: QtObject {
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
