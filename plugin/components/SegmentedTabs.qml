import QtQuick
import QtQuick.Layouts

// The detail tabs: one strip with a hairline under it; the current tab gets
// the selected fill and the theme's accent underline.
Item {
    id: root

    required property var theme
    // [{key, label, icon?, count?, visible?}]
    property var tabs: []
    property string current: ""

    signal selected(string key)

    implicitHeight: theme.space(32)

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: root.theme.line
    }

    RowLayout {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        spacing: root.theme.space(2)
        Repeater {
            model: root.tabs.filter(function (t) { return t.visible !== false })
            Item {
                id: tab
                required property var modelData
                readonly property bool on: modelData.key === root.current
                Layout.fillHeight: true
                implicitWidth: row.implicitWidth + root.theme.space(24)
                Rectangle {
                    anchors.fill: parent
                    color: tab.on ? root.theme.selectedFill : mouse.containsMouse ? root.theme.hoverFill : "transparent"
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    visible: tab.on
                    color: root.theme.accent
                }
                RowLayout {
                    id: row
                    anchors.centerIn: parent
                    spacing: root.theme.space(6)
                    Icon { theme: root.theme; visible: !!tab.modelData.icon; name: tab.modelData.icon || ""; size: root.theme.body; color: root.theme.accentText }
                    Text {
                        text: tab.modelData.label
                        color: tab.on ? root.theme.bright : mouse.containsMouse ? root.theme.text : root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.body
                        textFormat: Text.PlainText
                    }
                    Text {
                        visible: tab.modelData.count !== undefined && tab.modelData.count !== null
                        text: String(tab.modelData.count)
                        color: root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.body
                        textFormat: Text.PlainText
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
