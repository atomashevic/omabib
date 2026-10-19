import QtQuick

// A soft drop shadow under the parent: a few widening, translucent rounded
// layers, much cheaper than a blur. Put it inside the raised item.
Item {
    id: root

    required property var theme
    property real radius: 0
    // How far the shadow reaches, in unscaled pixels.
    property real reach: 12
    property real strength: 1

    anchors.fill: parent
    z: -1

    Repeater {
        model: 4
        Rectangle {
            required property int index
            readonly property real spread: root.theme.space(root.reach) * (index + 1) / 4
            x: -spread
            y: -spread + spread * 0.6
            width: root.width + 2 * spread
            height: root.height + 2 * spread
            radius: root.radius + spread
            color: Qt.rgba(0, 0, 0, (root.theme.light ? 0.022 : 0.06) * root.strength)
        }
    }
}
