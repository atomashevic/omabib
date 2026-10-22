import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

// The bar over an open paper: the way back, named for where it goes, the
// paper's title and authors, the switch between its details and its PDF,
// and the chat and notes-pane controls.
Rectangle {
    id: root

    required property var theme
    required property var app

    readonly property var paper: app.activePaper || ({})
    // Authors come with the reference, once it has loaded.
    readonly property var reference: app.selected && app.selected.id === paper.id ? app.selected : null

    implicitHeight: theme.space(52)
    color: theme.side

    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.line }

    RowLayout {
        anchors { fill: parent; leftMargin: root.theme.space(12); rightMargin: root.theme.space(14); bottomMargin: 1 }
        spacing: root.theme.space(14)

        Item {
            id: back
            objectName: "backToLibrary"
            Layout.maximumWidth: root.theme.space(320)
            implicitWidth: backRow.implicitWidth + root.theme.space(18)
            implicitHeight: root.theme.space(30)
            Rectangle {
                anchors.fill: parent
                radius: root.theme.radius
                color: backHover.hovered ? root.theme.hoverFill : root.theme.raised
                border.color: root.theme.line
                Behavior on color { ColorAnimation { duration: 120 } }
            }
            HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.app.activateTab(-1) }
            RowLayout {
                id: backRow
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(7); rightMargin: root.theme.space(9) }
                spacing: root.theme.space(6)
                Icon { theme: root.theme; name: "chevronLeft"; size: root.theme.title; color: root.theme.text }
                Text {
                    Layout.fillWidth: true
                    text: root.app.backLabel
                    color: root.theme.bright
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.body
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Keycap { theme: root.theme; text: "Esc" }
            }
            Tip { theme: root.theme; visible: backHover.hovered; text: "Back to the library, as you left it" }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
                Layout.fillWidth: true
                text: root.paper.title || root.paper.citekey || ""
                color: root.theme.bright
                font.family: root.theme.sans
                font.pixelSize: root.theme.body + 1
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.reference ? [Format.shortAuthors(root.reference.authors), root.reference.year].filter(function (s) { return !!s }).join(" · ") : ""
                color: root.theme.muted
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }

        // The tab's two views. Ctrl+O switches between them too.
        Rectangle {
            id: views
            objectName: "tabViews"
            implicitWidth: viewRow.implicitWidth + root.theme.space(8)
            implicitHeight: root.theme.space(32)
            radius: root.theme.radius + 1
            color: root.theme.app
            border.width: 1
            border.color: root.theme.line
            RowLayout {
                id: viewRow
                anchors { left: parent.left; leftMargin: root.theme.space(3); verticalCenter: parent.verticalCenter }
                spacing: root.theme.space(2)
                Repeater {
                    model: [{ key: "info", label: "Info", icon: "info", tip: "The paper's details, notes and files" },
                            { key: "pdf", label: "PDF", icon: "pdf", tip: "Read the PDF; Omabib finds one if it's missing" }]
                    Rectangle {
                        id: view
                        required property var modelData
                        readonly property bool current: (modelData.key === "pdf") === root.app.inPdfTab
                        objectName: "tabView:" + modelData.key
                        implicitWidth: viewLabel.implicitWidth + root.theme.space(22)
                        implicitHeight: root.theme.space(26)
                        radius: root.theme.radius
                        color: current ? root.theme.selectedFill : viewHover.hovered ? root.theme.hoverFill : "transparent"
                        border.width: current ? 1 : 0
                        border.color: root.theme.line
                        RowLayout {
                            id: viewLabel
                            anchors.centerIn: parent
                            spacing: root.theme.space(6)
                            Icon { theme: root.theme; name: view.modelData.icon; size: root.theme.title; color: view.current ? root.theme.accentText : root.theme.muted }
                            Text {
                                text: view.modelData.label
                                color: view.current ? root.theme.bright : root.theme.muted
                                font.family: root.theme.sans
                                font.pixelSize: root.theme.body
                                font.weight: view.current ? Font.DemiBold : Font.Medium
                                textFormat: Text.PlainText
                            }
                        }
                        HoverHandler { id: viewHover; cursorShape: view.current ? Qt.ArrowCursor : Qt.PointingHandCursor }
                        TapHandler { onTapped: if (!view.current) { view.modelData.key === "pdf" ? root.app.showPdf() : root.app.showInfo() } }
                        Tip { theme: root.theme; visible: viewHover.hovered && !view.current; text: view.modelData.tip + "  ·  " + root.app.pdfShortcut }
                    }
                }
            }
        }
        TextButton {
            theme: root.theme
            icon: "sparkles"
            text: "Ask " + (root.app.chatAgent === "codex" ? "Codex" : "Claude")
            onClicked: root.app.focusChat()
        }
        IconButton {
            visible: root.app.inPdfTab && !!root.app.readerPane
            theme: root.theme
            icon: "sidebar"
            size: root.theme.space(30)
            iconSize: root.theme.title + 1
            iconColor: root.theme.muted
            active: !!root.app.readerPane && root.app.readerPane.showSide
            tooltip: "Notes pane"
            shortcut: "]"
            onClicked: root.app.readerPane.showSide = !root.app.readerPane.showSide
        }
    }
}
