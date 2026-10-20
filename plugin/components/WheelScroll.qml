import QtQuick
import "Wheel.js" as Wheel

// Scrolls the Flickable this sits in. A mouse notch moves three lines.
// A touchpad moves by the pixels it reports.
WheelHandler {
    id: root

    property var theme: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    function view() {
        var item = parent
        while (item && item.flicking === undefined)
            item = item.parent
        return item
    }

    onWheel: (event) => Wheel.apply(root.view(), event, Wheel.stepFor(root.theme))
}
