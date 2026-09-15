import QtQuick
import QtQuick.Layouts

// A centred icon, a line saying what is (or isn't) here, and what to do next.
ColumnLayout {
    id: root

    required property var theme
    property string icon: "book"
    property string title: ""
    property string hint: ""
    property string detail: ""
    property color iconColor: theme.accentText
    default property alias actions: actionRow.data

    spacing: theme.space(10)

    Rectangle {
        Layout.alignment: Qt.AlignHCenter
        Layout.bottomMargin: root.theme.space(2)
        implicitWidth: root.theme.space(44); implicitHeight: implicitWidth
        radius: root.theme.radius
        color: "transparent"
        border.width: 1
        border.color: root.theme.line
        Icon { theme: root.theme; anchors.centerIn: parent; name: root.icon; size: root.theme.space(22); color: root.iconColor }
    }
    Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.fillWidth: true
        Layout.maximumWidth: root.theme.space(420)
        visible: text !== ""
        text: root.title
        color: root.theme.bright
        font.family: root.theme.mono
        font.pixelSize: root.theme.subtitle
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.fillWidth: true
        Layout.maximumWidth: root.theme.space(460)
        visible: text !== ""
        text: root.hint
        color: root.theme.muted
        font.family: root.theme.mono
        font.pixelSize: root.theme.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        textFormat: Text.StyledText
    }
    Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.fillWidth: true
        Layout.maximumWidth: root.theme.space(460)
        visible: text !== ""
        text: root.detail
        color: root.theme.dim
        font.family: root.theme.mono
        font.pixelSize: root.theme.small
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    RowLayout {
        id: actionRow
        Layout.alignment: Qt.AlignHCenter
        Layout.topMargin: root.theme.space(4)
        spacing: root.theme.space(8)
    }
}
