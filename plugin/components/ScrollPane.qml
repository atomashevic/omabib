import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A vertically scrolling column capped at a readable measure, with the
// detail pane's side margins. Children go into `content`.
Flickable {
    id: root

    required property var theme
    property real measure: theme.space(700)
    property real sidePadding: theme.space(24)
    property real topPadding: theme.space(18)
    default property alias content: column.data
    property alias column: column

    clip: true
    contentWidth: width
    contentHeight: column.implicitHeight + topPadding + theme.space(28)
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    ColumnLayout {
        id: column
        x: root.sidePadding
        y: root.topPadding
        width: Math.min(root.measure, root.width - root.sidePadding * 2)
        spacing: root.theme.space(14)
    }

    ScrollBar.vertical: ScrollBar {
        policy: ScrollBar.AsNeeded
        contentItem: Rectangle { implicitWidth: root.theme.space(4); color: root.theme.line }
    }

    function scrollToItem(item) {
        var y = item.mapToItem(column, 0, 0).y + root.topPadding - root.theme.space(8)
        contentY = Math.max(0, Math.min(y, contentHeight - height))
    }

    Behavior on contentY { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
}
