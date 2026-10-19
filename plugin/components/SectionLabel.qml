import QtQuick

Text {
    required property var theme
    color: theme.muted
    font.family: theme.sans
    font.pixelSize: theme.small
    font.weight: Font.DemiBold
    textFormat: Text.PlainText
}
