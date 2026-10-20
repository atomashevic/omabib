import QtQuick

// The Omabib mark: the brackets of a citation around a point. Drawn on a
// 24-unit grid in one color so the bar and the rail follow the shell theme.
Canvas {
    id: root

    property color color: "white"

    implicitWidth: 24
    implicitHeight: 24
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var c = getContext("2d")
        c.reset()
        var s = Math.min(width, height) / 24
        c.translate((width - 24 * s) / 2, (height - 24 * s) / 2)
        c.scale(s, s)
        c.strokeStyle = root.color
        c.fillStyle = root.color
        c.lineWidth = 2.4
        c.lineCap = "round"
        c.lineJoin = "round"
        c.beginPath()
        c.moveTo(7.6, 3.2)
        c.lineTo(3.6, 3.2)
        c.lineTo(3.6, 20.8)
        c.lineTo(7.6, 20.8)
        c.moveTo(16.4, 3.2)
        c.lineTo(20.4, 3.2)
        c.lineTo(20.4, 20.8)
        c.lineTo(16.4, 20.8)
        c.stroke()
        c.beginPath()
        c.arc(12, 12, 2.7, 0, Math.PI * 2)
        c.fill()
    }
}
