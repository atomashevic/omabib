import QtQuick
import QtTest
import WheelSend
import "../../plugin/components"
import "../../plugin/components/Wheel.js" as Wheel

// Offscreen check of one mouse notch and one touchpad swipe, on a plain
// Flickable and on the shared handler.
Item {
    width: 660
    height: 220

    Flickable {
        id: plain
        objectName: "plain"
        width: 200
        height: 200
        contentWidth: width
        contentHeight: 8000
        boundsBehavior: Flickable.StopAtBounds
        Rectangle { width: plain.contentWidth; height: plain.contentHeight; color: "transparent" }
    }

    Flickable {
        id: fixed
        objectName: "fixed"
        x: 220
        width: 200
        height: 200
        contentWidth: width
        contentHeight: 8000
        boundsBehavior: Flickable.StopAtBounds
        Rectangle { width: fixed.contentWidth; height: fixed.contentHeight; color: "transparent" }
        WheelScroll {}
    }

    // Settings and sync put the handler on the column inside the scroll view.
    Flickable {
        id: nested
        objectName: "nested"
        x: 440
        width: 200
        height: 200
        contentWidth: width
        contentHeight: 8000
        boundsBehavior: Flickable.StopAtBounds
        Item {
            width: nested.width
            height: nested.contentHeight
            WheelScroll {}
        }
    }

    WheelSender { id: wheels }

    TestCase {
        name: "Wheel"
        when: windowShown

        function park(item) {
            item.contentY = 400
            wait(40)
            return item.contentY
        }

        function test_notch_and_pixels() {
            var step = Wheel.stepFor(null)
            compare(step, 72)

            var angleFrom = park(plain)
            wheels.send(plain, 0, -120, 0, 0)
            wait(500)
            var beforeAngle = plain.contentY - angleFrom

            var pixelFrom = park(plain)
            wheels.send(plain, 0, 0, 0, -40)
            wait(500)
            var beforePixel = plain.contentY - pixelFrom

            var fixedAngleFrom = park(fixed)
            wheels.send(fixed, 0, -120, 0, 0)
            var afterAngle = fixed.contentY - fixedAngleFrom

            var fixedPixelFrom = park(fixed)
            wheels.send(fixed, 0, 0, 0, -40)
            var afterPixel = fixed.contentY - fixedPixelFrom

            // A second event with the same timestamp. Flickable drops it.
            wheels.holdStamp = true
            var droppedFrom = park(plain)
            wheels.send(plain, 0, -120, 0, 0)
            wait(500)
            var firstSame = plain.contentY
            wheels.send(plain, 0, -120, 0, 0)
            wait(500)
            var beforeSame = plain.contentY - firstSame
            wheels.holdStamp = false
            var keptFrom = park(fixed)
            wheels.holdStamp = true
            wheels.send(fixed, 0, -120, 0, 0)
            wheels.send(fixed, 0, -120, 0, 0)
            wheels.holdStamp = false
            var afterSame = fixed.contentY - keptFrom

            var nestedFrom = park(nested)
            wheels.send(nested, 0, -120, 0, 0)
            var nestedAngle = nested.contentY - nestedFrom

            // One physical high-resolution notch often arrives as several small
            // angle deltas with one timestamp. Flickable keeps only the first.
            wheels.holdStamp = true
            var burstFrom = park(plain)
            for (var i = 0; i < 8; i++)
                wheels.send(plain, 0, -15, 0, 0)
            wait(500)
            var beforeBurst = plain.contentY - burstFrom
            var fixedBurstFrom = park(fixed)
            for (var j = 0; j < 8; j++)
                wheels.send(fixed, 0, -15, 0, 0)
            wheels.holdStamp = false
            var afterBurst = fixed.contentY - fixedBurstFrom

            console.log("wheel contentY angle before", beforeAngle, "after", afterAngle,
                        "pixel before", beforePixel, "after", afterPixel,
                        "same-stamp second before", beforeSame, "two notches after", afterSame,
                        "hires burst before", beforeBurst, "after", afterBurst)

            compare(beforeAngle, 72)
            compare(afterAngle, step)
            compare(beforePixel, 0)
            compare(afterPixel, 40)
            compare(beforeSame, 0)
            compare(afterSame, step * 2)
            compare(beforeBurst, 9)
            compare(afterBurst, step)
            compare(nestedAngle, step)
            verify(droppedFrom >= 0)
        }

        function test_touchpad_is_not_a_notch() {
            var step = Wheel.stepFor(null)
            // Qt's touchpad fallback angle is about 12 times the pixel delta.
            var from = park(fixed)
            wheels.send(fixed, 0, -480, 0, -40)
            compare(fixed.contentY - from, 40)
            verify(fixed.contentY - from !== step)
            // A mouse notch that also carries a small pixel delta stays a notch.
            var notchFrom = park(fixed)
            wheels.send(fixed, 0, -120, 0, -15)
            compare(fixed.contentY - notchFrom, step)
        }
    }
}
