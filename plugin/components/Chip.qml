import QtQuick
import QtQuick.Layouts

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
    // A link-like pill (arXiv, DOI) in the accent tint.
    property bool accent: false
    // Set in the code face, for citation keys.
    property bool mono: false
    property color textColor: accent ? theme.accentText : selected ? theme.bright : theme.text
    property color iconColor: theme.muted
    property real maxTextWidth: theme.space(260)

    signal clicked()

    readonly property bool hot: clickable && mouse.containsMouse

    implicitHeight: theme.space(24)
    implicitWidth: row.implicitWidth + theme.space(18)

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.accent || root.selected ? root.theme.selectedFill : root.hot ? root.theme.hoverFill : root.bordered ? root.theme.side : "transparent"
        border.width: !root.accent && (root.bordered || root.selected) ? 1 : 0
        border.color: root.selected ? root.theme.accent : root.theme.line
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: root.theme.space(5)
        Icon { theme: root.theme; visible: root.icon !== ""; name: root.icon; size: root.theme.small + 1; color: root.iconColor }
        Text {
            visible: root.text !== ""
            text: root.text
            color: root.hot && !root.accent ? root.theme.bright : root.textColor
            font.family: root.mono ? root.theme.mono : root.theme.sans
            font.pixelSize: root.theme.small
            font.weight: root.accent ? Font.DemiBold : Font.Medium
            textFormat: Text.PlainText
            elide: Text.ElideRight
            Layout.maximumWidth: root.maxTextWidth
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

    Tip {
        theme: root.theme
        visible: root.tooltip !== "" && mouse.containsMouse
        text: root.tooltip
    }
}
