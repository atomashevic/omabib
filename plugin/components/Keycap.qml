import QtQuick

// A key or shortcut, as in the status bar and on buttons.
Rectangle {
    id: root

    required property var theme
    property string text: ""
    property bool onAccent: false

    implicitWidth: label.implicitWidth + theme.space(10)
    implicitHeight: label.implicitHeight + theme.space(2)
    radius: theme.space(4)
    color: onAccent ? Qt.rgba(1, 1, 1, 0.16) : theme.raised
    border.width: 1
    border.color: onAccent ? Qt.rgba(1, 1, 1, 0.35) : theme.line

    Text {
        id: label
        anchors.centerIn: parent
        text: root.theme.keys(root.text)
        color: root.onAccent ? root.theme.onAccent : root.theme.text
        font.family: root.theme.mono
        font.pixelSize: root.theme.caption
        textFormat: Text.PlainText
    }
}
