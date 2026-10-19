import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The theme's text input: a recessed field that lifts and takes an accent
// ring on focus, with an optional leading icon, a key hint while it is idle
// and a clear button once it has text. The field itself is exposed as `input`.
Item {
    id: root

    required property var theme
    property string icon: ""
    property string placeholder: ""
    property bool clearable: true
    // A key that focuses the field ("Ctrl+F"), shown while it is idle.
    property string hint: ""
    property real fontSize: theme.body
    // objectName of the inner field, for UI tests that look it up.
    property string inputName: ""
    property alias input: field
    property alias text: field.text

    // Forwarded so a parent can route keys without reaching into the field.
    signal keyPressed(var event)
    signal shortcutOverride(var event)

    implicitHeight: theme.space(32)
    implicitWidth: theme.space(200)

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: field.activeFocus ? root.theme.raised : root.theme.side
        border.width: field.activeFocus ? root.theme.focusBorderWidth : 1
        border.color: field.activeFocus ? root.theme.focusBorder : root.theme.line
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: root.theme.space(10)
        anchors.rightMargin: root.theme.space(6)
        spacing: root.theme.space(8)
        Icon { theme: root.theme; visible: root.icon !== ""; name: root.icon; size: root.fontSize + 2; color: root.theme.muted }
        TextField {
            id: field
            objectName: root.inputName
            Layout.fillWidth: true
            Layout.fillHeight: true
            leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
            verticalAlignment: TextInput.AlignVCenter
            placeholderText: root.placeholder
            placeholderTextColor: root.theme.dim
            color: root.theme.bright
            selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.35)
            selectedTextColor: root.theme.bright
            font.family: root.theme.sans
            font.pixelSize: root.fontSize
            selectByMouse: true
            background: Item {}
            Keys.onPressed: event => root.keyPressed(event)
            Keys.onShortcutOverride: event => root.shortcutOverride(event)
        }
        Keycap {
            theme: root.theme
            visible: root.hint !== "" && field.text === "" && !field.activeFocus
            text: root.hint
        }
        IconButton {
            theme: root.theme
            visible: root.clearable && field.text !== ""
            icon: "close"
            size: root.theme.space(22)
            iconSize: root.theme.body
            iconColor: root.theme.dim
            onClicked: { field.text = ""; field.forceActiveFocus() }
        }
    }
}
