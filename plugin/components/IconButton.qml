import QtQuick
import qs.Ui

// An icon-only control with the theme's hover/selected fills, a tooltip that
// names its shortcut, an optional status dot and a busy spin.
Item {
    id: root

    required property var theme
    property string icon: ""
    property string tooltip: ""
    property string shortcut: ""
    property bool active: false
    property bool busy: false
    property bool dot: false
    property color dotColor: theme.accentText
    property color iconColor: theme.text
    property color activeColor: theme.accentText
    property real iconSize: theme.title + 2
    property real size: theme.space(28)

    signal clicked()

    readonly property bool hot: mouse.containsMouse && enabled

    implicitWidth: size
    implicitHeight: size
    opacity: enabled || busy ? 1 : 0.4

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: mouse.pressed ? root.theme.pressedFill
            : root.active ? root.theme.line
            : root.hot ? root.theme.hoverFill : "transparent"
    }

    Icon {
        id: glyph
        theme: root.theme
        anchors.centerIn: parent
        name: root.icon
        size: root.iconSize
        color: root.active ? root.activeColor : root.hot ? root.theme.bright : root.iconColor
        RotationAnimation on rotation {
            running: root.busy
            loops: Animation.Infinite
            from: 0; to: 360; duration: 1000
            onRunningChanged: if (!running) glyph.rotation = 0
        }
    }

    Rectangle {
        visible: root.dot
        width: root.theme.space(6); height: width
        radius: root.theme.radius > 0 ? width / 2 : 0
        color: root.dotColor
        anchors { top: parent.top; right: parent.right; topMargin: root.size * 0.2; rightMargin: root.size * 0.2 }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.enabled) root.clicked()
    }

    PanelToolTip {
        visible: root.tooltip !== "" && mouse.containsMouse
        text: root.tooltip + (root.shortcut ? "  ·  " + root.shortcut : "")
        fontFamily: root.theme.mono
    }
}
