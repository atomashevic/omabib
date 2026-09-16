import QtQuick

// The Omabib mark: three book spines stacked inside a ring, the O. Drawn on a
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
        c.lineWidth = 1.6
        c.beginPath()
        c.arc(12, 12, 9.6, 0, Math.PI * 2)
        c.stroke()
        // Spines: x, y, width, height, with 0.7 corner radius.
        var spines = [[7.4, 6.6, 8.4, 2.9], [6.2, 10.6, 11.6, 2.9], [8.2, 14.6, 7.8, 2.9]]
        for (var i = 0; i < spines.length; i++) {
            var x = spines[i][0], y = spines[i][1], w = spines[i][2], h = spines[i][3], r = 0.7
            c.beginPath()
            c.moveTo(x + r, y)
            c.lineTo(x + w - r, y)
            c.quadraticCurveTo(x + w, y, x + w, y + r)
            c.lineTo(x + w, y + h - r)
            c.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
            c.lineTo(x + r, y + h)
            c.quadraticCurveTo(x, y + h, x, y + h - r)
            c.lineTo(x, y + r)
            c.quadraticCurveTo(x, y, x + r, y)
            c.fill()
        }
    }
}
