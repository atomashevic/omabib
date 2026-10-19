import QtQuick
import QtQuick.Controls

// A tooltip in the window's colors, in place of the shell's PanelToolTip so it
// follows the chosen theme everywhere.
ToolTip {
    id: tip

    required property var theme
    property string fontFamily: theme.sans

    delay: 450
    topPadding: theme.space(5)
    bottomPadding: theme.space(5)
    leftPadding: theme.space(9)
    rightPadding: theme.space(9)
    contentItem: Text {
        text: tip.text
        color: tip.theme.bright
        font.family: tip.fontFamily
        font.pixelSize: tip.theme.small
        textFormat: Text.PlainText
    }
    background: Rectangle {
        color: tip.theme.raised
        border.color: tip.theme.line
        radius: tip.theme.radiusSmall
    }
}
