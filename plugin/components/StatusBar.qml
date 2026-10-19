import QtQuick
import QtQuick.Layouts

// Key hints on the left; the latest notice fades in on the right.
Rectangle {
    id: root

    required property var theme
    // [[key, label], ...]
    property var hints: []
    property string notice: ""
    // Keeps the last notice on screen while it fades out.
    property string shown: ""
    onNoticeChanged: if (notice !== "") shown = notice

    implicitHeight: theme.space(30)
    color: theme.side

    Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top } height: 1; color: root.theme.line }

    RowLayout {
        anchors { fill: parent; leftMargin: root.theme.space(14); rightMargin: root.theme.space(14); topMargin: 1 }
        spacing: root.theme.space(16)
        Repeater {
            model: root.hints
            RowLayout {
                required property var modelData
                spacing: root.theme.space(6)
                Keycap { theme: root.theme; text: modelData[0] }
                Text { text: modelData[1]; color: root.theme.muted; font.family: root.theme.sans; font.pixelSize: root.theme.small; textFormat: Text.PlainText }
            }
        }
        Item { Layout.fillWidth: true }
        RowLayout {
            spacing: root.theme.space(6)
            opacity: root.notice !== "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Icon { theme: root.theme; name: "check"; size: root.theme.body; color: root.theme.success }
            Text {
                Layout.maximumWidth: root.theme.space(520)
                text: root.shown
                color: root.theme.bright
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                font.weight: Font.Medium
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }
    }
}
