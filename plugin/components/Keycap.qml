import QtQuick

Rectangle {
    id: root

    required property var theme
    property string text: ""
    property bool onAccent: false

    implicitWidth: label.implicitWidth + theme.space(8)
    implicitHeight: label.implicitHeight + theme.space(2)
    radius: theme.radius
    color: onAccent ? Qt.rgba(0, 0, 0, 0.18) : Qt.rgba(theme.text.r, theme.text.g, theme.text.b, 0.04)
    border.width: 1
    border.color: onAccent ? Qt.rgba(theme.bright.r, theme.bright.g, theme.bright.b, 0.45) : theme.controlBorder

    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: root.onAccent ? root.theme.bright : root.theme.text
        font.family: root.theme.mono
        font.pixelSize: root.theme.caption
        textFormat: Text.PlainText
    }
}
