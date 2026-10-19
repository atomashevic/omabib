import QtQuick
import QtQuick.Layouts

// The detail tabs: labels over a hairline; the current one is set in the
// strong text color with the accent underline, counts sit in small pills.
Item {
    id: root

    required property var theme
    // [{key, label, icon?, count?, visible?}]
    property var tabs: []
    property string current: ""

    signal selected(string key)

    implicitHeight: theme.space(34)

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: root.theme.line
    }

    RowLayout {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        spacing: root.theme.space(20)
        Repeater {
            model: root.tabs.filter(function (t) { return t.visible !== false })
            Item {
                id: tab
                required property var modelData
                readonly property bool on: modelData.key === root.current
                Layout.fillHeight: true
                implicitWidth: row.implicitWidth + root.theme.space(4)
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 2
                    radius: 1
                    color: root.theme.accent
                    opacity: tab.on ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }
                RowLayout {
                    id: row
                    anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter; verticalCenterOffset: -root.theme.space(2) }
                    spacing: root.theme.space(6)
                    Icon { theme: root.theme; visible: !!tab.modelData.icon; name: tab.modelData.icon || ""; size: root.theme.body + 1; color: tab.on ? root.theme.accentText : root.theme.muted }
                    Text {
                        text: tab.modelData.label
                        color: tab.on || mouse.containsMouse ? root.theme.bright : root.theme.muted
                        font.family: root.theme.sans
                        font.pixelSize: root.theme.body
                        font.weight: tab.on ? Font.DemiBold : Font.Medium
                        textFormat: Text.PlainText
                    }
                    Rectangle {
                        visible: tab.modelData.count !== undefined && tab.modelData.count !== null
                        implicitWidth: countText.implicitWidth + root.theme.space(12)
                        implicitHeight: countText.implicitHeight + root.theme.space(2)
                        radius: height / 2
                        color: root.theme.hoverFill
                        Text {
                            id: countText
                            anchors.centerIn: parent
                            text: String(tab.modelData.count)
                            color: root.theme.muted
                            font.family: root.theme.sans
                            font.pixelSize: root.theme.caption
                            font.weight: Font.DemiBold
                            textFormat: Text.PlainText
                        }
                    }
                }
                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selected(tab.modelData.key)
                }
            }
        }
    }
}
