import QtQuick
import QtQuick.Layouts
import qs.Ui

// A small labelled token: note scope, page, project, citation key, section.
Item {
    id: root

    required property var theme
    property string text: ""
    property string icon: ""
    property string trailingIcon: ""
    property string tooltip: ""
    property bool selected: false
    property bool clickable: false
    property bool bordered: true
    property color textColor: selected ? theme.bright : theme.text
    property color iconColor: theme.muted

    signal clicked()

    readonly property bool hot: clickable && mouse.containsMouse

    implicitHeight: theme.space(22)
    implicitWidth: row.implicitWidth + theme.space(14)

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: root.selected ? root.theme.selectedFill : root.hot ? root.theme.hoverFill : "transparent"
        border.width: root.bordered || root.selected ? 1 : 0
        border.color: root.selected ? root.theme.accent : root.theme.line
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: root.theme.space(5)
        Icon { theme: root.theme; visible: root.icon !== ""; name: root.icon; size: root.theme.small + 1; color: root.iconColor }
        Text {
            text: root.text
            color: root.hot ? root.theme.bright : root.textColor
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
            elide: Text.ElideRight
            Layout.maximumWidth: root.theme.space(260)
        }
        Icon { theme: root.theme; visible: root.trailingIcon !== ""; name: root.trailingIcon; size: root.theme.small + 1; color: root.hot ? root.theme.bright : root.theme.dim }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.clickable || root.tooltip !== ""
        hoverEnabled: true
        cursorShape: root.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.clickable) root.clicked()
    }

    PanelToolTip {
        visible: root.tooltip !== "" && mouse.containsMouse
        text: root.tooltip
        fontFamily: root.theme.mono
    }
}
