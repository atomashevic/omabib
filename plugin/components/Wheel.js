.pragma library

// A mouse notch and a touchpad swipe are different wheel events.
// Qt reports a notch as angleDelta, 120 units per click, and a touchpad as
// pixelDelta. Flickable turns a notch into a short flick (about 72px, and
// less when several events share a timestamp). A touchpad must stay 1:1.

var lines = 3
var line = 24

function stepFor(theme) {
    var px = theme && theme.space ? theme.space(line) : line
    return lines * px
}

// One axis. A pure angle is a notch. A pure pixelDelta is a touchpad.
// When both are set, a touchpad's angle is about 12 times its pixel delta
// (Qt's fallback). A mouse notch is not that ratio, so it keeps the line step.
function axis(angle, pixel, step) {
    if (pixel !== 0 && angle === 0) return pixel
    if (angle !== 0 && pixel === 0) return angle / 120 * step
    if (angle === 0) return 0
    var likeTouchpad = Math.abs(Math.abs(angle) - Math.abs(pixel) * 12) <= Math.max(2, Math.abs(pixel))
    if (likeTouchpad) return pixel
    return angle / 120 * step
}

function apply(flick, event, step) {
    if (!flick || !event) return false
    if (event.modifiers & Qt.ControlModifier) return false
    var dx = axis(event.angleDelta.x, event.pixelDelta.x, step)
    var dy = axis(event.angleDelta.y, event.pixelDelta.y, step)
    if ((event.modifiers & Qt.ShiftModifier) && dx === 0) { dx = dy; dy = 0 }
    if (dx === 0 && dy === 0) return false
    if (dx !== 0) {
        var maxX = Math.max(0, flick.contentWidth - flick.width)
        flick.contentX = Math.max(0, Math.min(flick.contentX - dx, maxX))
    }
    if (dy !== 0) {
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        flick.contentY = Math.max(0, Math.min(flick.contentY - dy, maxY))
    }
    event.accepted = true
    return true
}
