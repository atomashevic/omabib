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

    implicitHeight: theme.space(28)
    color: theme.app

    Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top } height: 1; color: root.theme.line }

    RowLayout {
        anchors { fill: parent; leftMargin: root.theme.space(12); rightMargin: root.theme.space(12) }
        spacing: root.theme.space(14)
        Repeater {
            model: root.hints
            RowLayout {
                required property var modelData
                spacing: root.theme.space(5)
                Keycap { theme: root.theme; text: modelData[0] }
                Text { text: modelData[1]; color: root.theme.dim; font.family: root.theme.mono; font.pixelSize: root.theme.caption; textFormat: Text.PlainText }
            }
        }
        Item { Layout.fillWidth: true }
        RowLayout {
            spacing: root.theme.space(6)
            opacity: root.notice !== "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Icon { theme: root.theme; name: "check"; size: root.theme.body; color: root.theme.accentText }
            Text {
                Layout.maximumWidth: root.theme.space(520)
                text: root.shown
                color: root.theme.bright
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }
    }
}
