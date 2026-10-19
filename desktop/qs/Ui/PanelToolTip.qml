import QtQuick
import QtQuick.Controls.Basic
import qs.Commons

// The shell's tooltip: theme colors and the font the caller names.
ToolTip {
    id: tip
    property string fontFamily: Style.font.menuFamily
    delay: 500
    font.family: fontFamily
    font.pixelSize: Style.font.bodySmall
    contentItem: Text {
        text: tip.text
        font: tip.font
        color: Color.tooltip.text
    }
    background: Rectangle {
        color: Color.tooltip.background
        border.color: Color.tooltip.border
        radius: Style.cornerRadius
    }
}
