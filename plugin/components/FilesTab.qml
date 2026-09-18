import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

ScrollPane {
    id: root

    required property var app
    readonly property var ref: app.selected
    readonly property var attachments: ref && ref.attachments ? ref.attachments : []

    SectionLabel { theme: root.theme; text: "Attachments" }

    EmptyState {
        theme: root.theme
        Layout.fillWidth: true
        Layout.topMargin: root.theme.space(24)
        Layout.bottomMargin: root.theme.space(12)
        visible: root.attachments.length === 0
        icon: "pdf"
        iconColor: root.theme.muted
        title: "No PDF linked yet"
        hint: "Attach a file you have, or let Omabib look for an open-access copy."
    }

    Repeater {
        model: root.attachments
        Rectangle {
            id: row
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: fileRow.implicitHeight + root.theme.space(24)
            color: root.theme.app
            border.width: 1
            border.color: root.theme.line
            radius: root.theme.radius
            RowLayout {
                id: fileRow
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(14); rightMargin: root.theme.space(8) }
                spacing: root.theme.space(12)
                Rectangle {
                    implicitWidth: root.theme.space(36); implicitHeight: root.theme.space(44)
                    color: "transparent"
                    border.width: 1
                    border.color: root.theme.line
                    Icon { theme: root.theme; anchors.centerIn: parent; name: row.modelData.exists ? "pdf" : "fileMissing"; size: root.theme.space(20); color: row.modelData.exists ? root.theme.accentText : root.theme.dim }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(3)
                    Text {
                        Layout.fillWidth: true
                        text: Format.basename(row.modelData.path)
                        color: row.modelData.exists ? root.theme.bright : root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.body
                        elide: Text.ElideMiddle
                        textFormat: Text.PlainText
                    }
                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.exists ? Format.dirname(row.modelData.path, root.app.homeDir) : "Not on this computer · Open PDF downloads it from sync"
                        color: row.modelData.exists ? root.theme.muted : root.theme.accentText
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        elide: Text.ElideMiddle
                        textFormat: Text.PlainText
                    }
                }
                TextButton { theme: root.theme; variant: "ghost"; visible: row.modelData.exists; icon: "external"; text: "Open"; fontSize: root.theme.small; onClicked: root.app.openExternal(root.app.fileUrl(row.modelData.path), null, true) }
                TextButton { theme: root.theme; variant: "ghost"; visible: row.modelData.exists; icon: "copy"; text: "Path"; fontSize: root.theme.small; onClicked: root.app.copy(row.modelData.path) }
                TextButton { theme: root.theme; variant: "ghost"; visible: !row.modelData.exists; icon: "download"; text: "Pull"; fontSize: root.theme.small; onClicked: root.app.pullPdf(row.modelData.id) }
                TextButton { theme: root.theme; variant: "ghost"; icon: "unlink"; text: "Remove link"; fontSize: root.theme.small; onClicked: root.app.removePdfLink(row.modelData.id) }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(8)
        TextButton { theme: root.theme; icon: "pdf"; text: "Attach PDF…"; onClicked: root.app.choosePdf() }
        TextButton { theme: root.theme; variant: "ghost"; icon: "download"; text: "Find open-access PDF"; busy: root.app.pdfBusy; onClicked: root.app.getPdf() }
        Item { Layout.fillWidth: true }
        Text {
            visible: root.attachments.length > 0
            text: "Removing a link keeps the file"
            color: root.theme.dim
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
        }
    }
}
