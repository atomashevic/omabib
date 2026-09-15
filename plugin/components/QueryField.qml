import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The theme's text input: focus border and fill, optional leading icon and
// a clear button. The field itself is exposed as `input`.
Item {
    id: root

    required property var theme
    property string icon: ""
    property string placeholder: ""
    property bool clearable: true
    property real fontSize: theme.subtitle
    // objectName of the inner field, for UI tests that look it up.
    property string inputName: ""
    property alias input: field
    property alias text: field.text

    // Forwarded so a parent can route keys without reaching into the field.
    signal keyPressed(var event)
    signal shortcutOverride(var event)

    implicitHeight: theme.space(34)
    implicitWidth: theme.space(200)

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: field.activeFocus ? root.theme.focusFill : Qt.rgba(root.theme.text.r, root.theme.text.g, root.theme.text.b, 0.04)
        border.width: field.activeFocus ? root.theme.focusBorderWidth : 1
        border.color: field.activeFocus ? root.theme.focusBorder : root.theme.controlBorder
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: root.theme.space(10)
        anchors.rightMargin: root.theme.space(6)
        spacing: root.theme.space(8)
        Icon { theme: root.theme; visible: root.icon !== ""; name: root.icon; size: root.fontSize + 3; color: root.theme.muted }
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
            selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.55)
            selectedTextColor: root.theme.bright
            font.family: root.theme.mono
            font.pixelSize: root.fontSize
            selectByMouse: true
            background: Item {}
            Keys.onPressed: event => root.keyPressed(event)
            Keys.onShortcutOverride: event => root.shortcutOverride(event)
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
