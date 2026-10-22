import QtQuick
import QtQuick.Layouts

// The library's toolbar: the sidebar toggle, where you are, the search field
// (which routes the list's keys), Add PDF, Add and the actions palette.
Rectangle {
    id: root

    required property var theme
    required property var app
    readonly property Item queryField: search.input
    readonly property Item titleAnchor: title

    implicitHeight: theme.space(52)
    color: theme.app

    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.line }

    RowLayout {
        anchors { fill: parent; leftMargin: root.theme.space(10); rightMargin: root.theme.space(14); bottomMargin: 1 }
        spacing: root.theme.space(12)

        IconButton {
            theme: root.theme
            icon: "sidebarLeft"
            size: root.theme.space(30)
            iconSize: root.theme.title + 2
            iconColor: root.theme.muted
            active: !root.app.sidebarOpen
            tooltip: root.app.sidebarOpen ? "Hide the sidebar" : "Show the sidebar"
            onClicked: root.app.sidebarOpen = !root.app.sidebarOpen
        }

        ColumnLayout {
            id: title
            Layout.fillWidth: true
            Layout.minimumWidth: root.theme.space(120)
            spacing: 0
            Text {
                Layout.fillWidth: true
                text: root.app.placeLabel
                color: root.theme.bright
                font.family: root.theme.sans
                font.pixelSize: root.theme.subtitle
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.app.placeSummary
                color: root.theme.muted
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }

        QueryField {
            id: search
            Layout.preferredWidth: Math.min(root.theme.space(440), Math.max(root.theme.space(220), root.width * 0.38))
            theme: root.theme
            icon: "search"
            hint: "Ctrl+F"
            placeholder: "Search titles, authors, abstracts, notes"
            inputName: "searchField"
            onTextChanged: root.app.queryEdited()
            onShortcutOverride: event => {
                if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_U || event.key === Qt.Key_O || event.key === Qt.Key_Return || event.key === Qt.Key_Enter))
                    event.accepted = true
                else if (event.key === Qt.Key_Q && event.modifiers === Qt.NoModifier && search.text.trim() === "")
                    event.accepted = true
            }
            onKeyPressed: event => {
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                if (event.key === Qt.Key_Q && event.modifiers === Qt.NoModifier && search.text.trim() === "") { root.app.dismiss(); event.accepted = true }
                else if (ctrl && event.key === Qt.Key_U) { root.app.openLink(); event.accepted = true }
                else if (ctrl && event.key === Qt.Key_O) { root.app.getPdf(); event.accepted = true }
                else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) { root.app.navigate(1); event.accepted = true }
                else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) { root.app.navigate(-1); event.accepted = true }
                else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.app.openInTab(null, false); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (root.app.hits.length === 0 && root.app.looksLikeIdentifier(search.text)) root.app.startQuickAdd(search.text.trim())
                    else root.app.openPdf()
                    event.accepted = true
                }
                else if (event.key === Qt.Key_Tab) { root.app.showDetail(); event.accepted = true }
            }
        }

        TextButton {
            id: addPdf
            objectName: "addPdfButton"
            visible: root.width > root.theme.space(620)
            theme: root.theme
            icon: "pdf"
            text: "Add PDF"
            onClicked: root.app.openPdfPicker()
        }
        // A narrow window keeps the button as an icon.
        IconButton {
            visible: !addPdf.visible
            theme: root.theme
            icon: "pdf"
            size: root.theme.space(30)
            iconSize: root.theme.title + 1
            tooltip: "Add PDF"
            onClicked: root.app.openPdfPicker()
        }
        TextButton {
            objectName: "addButton"
            theme: root.theme
            variant: "primary"
            icon: "plus"
            text: "Add"
            onClicked: root.app.edit("quick")
        }
        IconButton {
            theme: root.theme
            icon: "command"
            size: root.theme.space(30)
            iconSize: root.theme.title + 1
            iconColor: root.theme.muted
            tooltip: "Actions"
            shortcut: "Ctrl+K"
            onClicked: root.app.openCommands()
        }
    }
}
