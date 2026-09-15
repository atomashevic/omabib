import QtQuick
import QtQuick.Layouts

// Icon + label control. Variants: "outline" (default), "ghost", "primary"
// (accent fill, for the one committing action in a dialog), "danger".
Item {
    id: root

    required property var theme
    property string text: ""
    property string icon: ""
    property string variant: "outline"
    property string shortcut: ""
    property bool busy: false
    property bool focusable: false
    property real fontSize: theme.body

    signal clicked()

    readonly property bool hot: mouse.containsMouse && enabled
    readonly property color foreground: variant === "primary" ? theme.bright
        : variant === "danger" ? theme.urgent
        : variant === "ghost" ? (hot ? theme.bright : theme.muted)
        : theme.text

    implicitHeight: theme.space(28)
    implicitWidth: row.implicitWidth + theme.space(20)
    opacity: enabled || busy ? 1 : 0.45
    activeFocusOnTab: focusable

    Keys.onReturnPressed: if (enabled) clicked()
    Keys.onSpacePressed: if (enabled) clicked()

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: root.variant === "primary"
            ? (mouse.pressed ? Qt.darker(root.theme.accent, 1.15) : root.hot ? Qt.lighter(root.theme.accent, 1.12) : root.theme.accent)
            : mouse.pressed ? root.theme.pressedFill
            : root.hot ? (root.variant === "danger" ? Qt.rgba(root.theme.urgent.r, root.theme.urgent.g, root.theme.urgent.b, 0.14) : root.theme.hoverFill)
            : "transparent"
        border.width: root.activeFocus ? root.theme.focusBorderWidth : (root.variant === "outline" ? 1 : 0)
        border.color: root.activeFocus ? root.theme.focusBorder : root.theme.controlBorder
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: root.theme.space(6)
        Icon {
            theme: root.theme
            visible: root.icon !== ""
            name: root.busy ? "refresh" : root.icon
            size: root.fontSize + 2
            color: root.foreground
            RotationAnimation on rotation { running: root.busy; loops: Animation.Infinite; from: 0; to: 360; duration: 1000 }
        }
        Text {
            text: root.text
            visible: text !== ""
            color: root.foreground
            font.family: root.theme.mono
            font.pixelSize: root.fontSize
            textFormat: Text.PlainText
        }
        Keycap {
            theme: root.theme
            visible: root.shortcut !== ""
            text: root.shortcut
            onAccent: root.variant === "primary"
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.enabled && !root.busy) root.clicked()
    }
}
