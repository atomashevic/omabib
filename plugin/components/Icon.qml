import QtQuick
import "Icons.js" as Icons

// One named glyph, centred on its ink rather than its font cell so a row of
// different icons lines up (the same correction Omamail and the shell's
// OpticalGlyph make).
Item {
    id: root

    required property var theme
    property string name: ""
    property color color: theme.text
    property real size: theme.title + 2

    readonly property string glyph: Icons.glyph(name)

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    TextMetrics {
        id: metrics
        font.family: root.theme.iconFamily
        font.pixelSize: Math.max(1, Math.round(root.size))
        text: root.glyph
    }

    Text {
        id: glyphText
        visible: root.glyph !== ""
        textFormat: Text.PlainText
        text: root.glyph
        color: root.color
        font.family: root.theme.iconFamily
        font.pixelSize: metrics.font.pixelSize
        x: (root.width - metrics.tightBoundingRect.width) / 2 - metrics.tightBoundingRect.x
        y: (root.height - metrics.tightBoundingRect.height) / 2 - (glyphText.baselineOffset + metrics.tightBoundingRect.y)
    }
}
