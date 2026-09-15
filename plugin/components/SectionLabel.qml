import QtQuick

Text {
    required property var theme
    color: theme.dim
    font.family: theme.mono
    font.pixelSize: theme.small
    textFormat: Text.PlainText
}
