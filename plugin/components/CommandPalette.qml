import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Ctrl+K. Letters filter; digits still run the numbered actions, so muscle
// memory from the old numbered list keeps working.
Popup {
    id: root

    required property var theme
    required property var app

    readonly property var actions: [
        {n: 1, group: "Add", icon: "plus", label: "Add new item", hint: "DOI, arXiv ID, URL or BibTeX", shortcut: "Super+Alt+B"},
        {n: 6, group: "Add", icon: "braces", label: "Paste BibTeX"},
        {n: 7, group: "Add", icon: "file", label: "Import BibTeX file…"},
        {n: 8, group: "Add", icon: "link", label: "Add DOI"},
        {n: 11, group: "Open", icon: "external", label: "Open link", shortcut: "Ctrl+U", ref: true},
        {n: 12, group: "Open", icon: "pdf", label: "Open PDF", hint: "downloads if needed", shortcut: app.pdfShortcut, ref: true},
        {n: 25, group: "Open", icon: "tabPlus", label: "Open in a new tab", shortcut: "Ctrl+T", ref: true},
        {n: 26, group: "Open", icon: "close", label: "Close tab", shortcut: "Ctrl+W"},
        {n: 2, group: "Copy", icon: "copy", label: "Copy citation key", ref: true},
        {n: 3, group: "Copy", icon: "copy", label: "Copy LaTeX citation", hint: "\\cite{…}", ref: true},
        {n: 4, group: "Copy", icon: "copy", label: "Copy Pandoc / Quarto citation", hint: "[@…]", ref: true},
        {n: 5, group: "Copy", icon: "braces", label: "Copy BibTeX", ref: true},
        {n: 13, group: "Copy", icon: "copy", label: "Copy PDF path", ref: true},
        {n: 9, group: "Reference", icon: "notePlus", label: "New note", ref: true},
        {n: 10, group: "Reference", icon: "pdf", label: "Attach PDF…", ref: true},
        {n: 14, group: "Reference", icon: "refresh", label: "Fill metadata online", hint: "abstract, DOI, venue", ref: true},
        {n: 15, group: "Reference", icon: "folder", label: "Assign to project…", ref: true},
        {n: 16, group: "Project", icon: "folderOpen", label: "Create project"},
        {n: 17, group: "Project", icon: "braces", label: "Copy project bibliography"},
        {n: 18, group: "Project", icon: "note", label: "Copy project notes"},
        {n: 19, group: "Sync", icon: "sync", label: "Sync history", hint: app.syncChipText()},
        {n: 20, group: "Sync", icon: "branch", label: "Repository settings"},
        {n: 22, group: "Agents", icon: "terminal", label: "Chat about item in " + app.cliName, ref: true},
        {n: 23, group: "Agents", icon: "chat", label: "Chat about item in " + app.desktopName, ref: true},
        {n: 24, group: "Settings", icon: "cog", label: "Settings…", hint: "PDF colors, chat apps"},
        {n: 27, group: "Settings", icon: "pageColors", label: app.pdfThemed ? "PDF pages in original colors" : "PDF pages in theme colors", shortcut: "Ctrl+R"},
        {n: 21, group: "Danger", icon: "trash", label: "Delete current item…", danger: true, ref: true}
    ]

    property string filter: ""
    property int cursor: 0

    readonly property var matches: {
        var words = filter.toLowerCase().split(/\s+/).filter(function (w) { return w.length > 0 })
        return actions.filter(function (a) {
            var hay = (a.label + " " + (a.hint || "") + " " + a.group).toLowerCase()
            return words.every(function (w) { return hay.indexOf(w) >= 0 })
        })
    }
    // Section headings interleaved with the matches; each action row carries
    // its position in `matches` as `mi` (var arrays don't keep object identity).
    readonly property var rows: {
        var out = [], last = ""
        for (var i = 0; i < matches.length; i++) {
            if (matches[i].group !== last) { out.push({section: matches[i].group}); last = matches[i].group }
            out.push(Object.assign({mi: i}, matches[i]))
        }
        return out
    }

    function run(action) {
        if (!action) return
        root.app.runAction(action.n)
    }
    function move(delta) {
        if (!matches.length) return
        cursor = Math.max(0, Math.min(matches.length - 1, cursor + delta))
        for (var i = 0; i < rows.length; i++)
            if (rows[i].mi === cursor) list.positionViewAtIndex(i, ListView.Contain)
    }

    onFilterChanged: cursor = 0
    onOpened: {
        filter = ""
        field.text = ""
        cursor = 0
        root.app.clearActionDigits()
        list.positionViewAtBeginning()
        field.forceActiveFocus()
    }
    onClosed: root.app.clearActionDigits()

    x: Math.round((parent.width - width) / 2)
    y: Math.round(Math.max(theme.space(40), (parent.height - height) / 3))
    width: Math.min(parent.width - theme.space(48), theme.space(560))
    height: Math.min(parent.height - theme.space(80), theme.space(600))
    modal: true
    focus: true
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Overlay.modal: Rectangle { color: root.theme.scrim }
    background: Rectangle {
        color: root.theme.card
        border.width: 1
        border.color: root.theme.border
        radius: root.theme.radius
    }

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: root.theme.space(52)
            Layout.leftMargin: root.theme.space(16)
            Layout.rightMargin: root.theme.space(14)
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: "command"; size: root.theme.heading; color: root.theme.muted }
            TextInput {
                id: field
                objectName: "commandFilter"
                Layout.fillWidth: true
                color: root.theme.bright
                font.family: root.theme.mono
                font.pixelSize: root.theme.subtitle + 1
                selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.55)
                selectedTextColor: root.theme.bright
                clip: true
                onTextChanged: root.filter = text
                Text {
                    anchors.fill: parent
                    visible: field.text === ""
                    text: root.app.actionDigits !== "" ? "Action " + root.app.actionDigits + "…  ↵ to run now" : "Type a command, or a number…"
                    color: root.app.actionDigits !== "" ? root.theme.accentText : root.theme.dim
                    font: field.font
                    verticalAlignment: Text.AlignVCenter
                }
                Keys.onPressed: event => {
                    if (field.text === "" && /^[0-9]$/.test(event.text) && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
                        root.app.actionDigit(event.text)
                        event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (root.app.actionDigits !== "") root.app.runAction(Number(root.app.actionDigits))
                        else root.run(root.matches[root.cursor])
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
                        root.move(1); event.accepted = true
                    } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
                        root.move(-1); event.accepted = true
                    } else if (event.key === Qt.Key_Backspace && field.text === "" && root.app.actionDigits !== "") {
                        root.app.clearActionDigits(); event.accepted = true
                    }
                }
            }
            Keycap { theme: root.theme; text: "esc" }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.line }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds
            header: Item { width: list.width; height: root.theme.space(4) }
            footer: Item { width: list.width; height: root.theme.space(6) }
            ScrollBar.vertical: ScrollBar { contentItem: Rectangle { implicitWidth: root.theme.space(4); color: root.theme.line } }

            delegate: Item {
                id: row
                required property var modelData
                readonly property bool isSection: !!modelData.section
                readonly property int matchIndex: isSection ? -1 : modelData.mi
                readonly property bool digitHit: !isSection && root.app.actionDigits !== "" && String(modelData.n) === root.app.actionDigits
                readonly property bool hot: digitHit || (root.app.actionDigits === "" && matchIndex === root.cursor)
                readonly property bool unavailable: !isSection && !!modelData.ref && root.app.hits.length === 0
                width: list.width
                height: isSection ? root.theme.space(28) : root.theme.space(34)

                Text {
                    visible: row.isSection
                    anchors { left: parent.left; leftMargin: root.theme.space(16); bottom: parent.bottom; bottomMargin: root.theme.space(5) }
                    text: String(row.modelData.section || "").toUpperCase()
                    color: row.modelData.section === "Danger" ? root.theme.urgent : root.theme.dim
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.caption
                    font.letterSpacing: 0.6
                }
                Rectangle {
                    visible: !row.isSection
                    anchors.fill: parent
                    color: row.hot ? root.theme.line : mouse.containsMouse ? root.theme.hoverFill : "transparent"
                    Rectangle { visible: row.hot; anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 2; color: root.theme.accent }
                }
                RowLayout {
                    visible: !row.isSection
                    anchors { fill: parent; leftMargin: root.theme.space(16); rightMargin: root.theme.space(16) }
                    spacing: root.theme.space(10)
                    opacity: row.unavailable ? 0.45 : 1
                    Icon {
                        theme: root.theme
                        name: row.modelData.icon || ""
                        size: root.theme.title + 1
                        color: row.modelData.danger ? root.theme.urgent : row.hot ? root.theme.accentText : root.theme.muted
                    }
                    Text {
                        text: row.modelData.label || ""
                        color: row.modelData.danger ? root.theme.urgent : row.hot ? root.theme.bright : root.theme.text
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.body + 1
                        textFormat: Text.PlainText
                    }
                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.hint || ""
                        color: root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Keycap { theme: root.theme; visible: !!row.modelData.shortcut; text: row.modelData.shortcut || "" }
                    Text {
                        Layout.preferredWidth: root.theme.space(20)
                        horizontalAlignment: Text.AlignRight
                        text: row.isSection ? "" : String(row.modelData.n)
                        color: row.digitHit ? root.theme.accentText : root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        font.weight: row.digitHit ? Font.Bold : Font.Normal
                    }
                }
                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    enabled: !row.isSection
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.run(row.modelData)
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: root.theme.space(20)
            Layout.bottomMargin: root.theme.space(20)
            visible: root.matches.length === 0
            horizontalAlignment: Text.AlignHCenter
            text: "No matching action"
            color: root.theme.dim
            font.family: root.theme.mono
            font.pixelSize: root.theme.body
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.line }
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: root.theme.space(30)
            Layout.leftMargin: root.theme.space(16)
            Layout.rightMargin: root.theme.space(16)
            spacing: root.theme.space(14)
            Repeater {
                model: [["↑↓", "select"], ["↵", "run"], ["0–9", "numbered action"], ["esc", "close"]]
                RowLayout {
                    required property var modelData
                    spacing: root.theme.space(5)
                    Keycap { theme: root.theme; text: modelData[0] }
                    Text { text: modelData[1]; color: root.theme.dim; font.family: root.theme.mono; font.pixelSize: root.theme.caption }
                }
            }
            Item { Layout.fillWidth: true }
        }
    }
}
