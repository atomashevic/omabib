import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

// The selected reference: header, icon toolbar, tabs.
Rectangle {
    id: root

    required property var theme
    required property var app

    readonly property var ref: app.selected
    readonly property string arxiv: Format.arxivId(ref)
    readonly property var tabKeys: ["overview", "ai", "notes", "files", "bibtex"]

    color: theme.card

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        visible: !!root.ref
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: root.theme.space(24)
            Layout.rightMargin: root.theme.space(18)
            Layout.topMargin: root.theme.space(18)
            spacing: root.theme.space(8)

            Text {
                Layout.fillWidth: true
                Layout.maximumWidth: root.theme.space(820)
                text: root.ref ? (root.ref.title || root.ref.citekey) : ""
                color: root.theme.bright
                font.family: root.theme.readingFamily
                font.pixelSize: root.theme.display
                font.weight: Font.DemiBold
                lineHeight: 1.12
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.ref ? Format.fullAuthors(root.ref.authors, 8) : ""
                color: root.theme.text
                font.family: root.theme.readingFamily
                font.pixelSize: root.theme.title
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Flow {
                Layout.fillWidth: true
                spacing: root.theme.space(8)
                Repeater {
                    model: root.ref ? [Format.venue(root.ref), root.ref.year].filter(function (s) { return !!s }) : []
                    Text {
                        required property var modelData
                        required property int index
                        height: root.theme.space(22)
                        verticalAlignment: Text.AlignVCenter
                        text: (index > 0 ? "·  " : "") + modelData
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        textFormat: Text.PlainText
                    }
                }
                Chip {
                    theme: root.theme
                    visible: !!(root.ref && root.ref.fields && root.ref.fields.doi) && root.arxiv === ""
                    text: root.ref && root.ref.fields ? (root.ref.fields.doi || "") : ""
                    textColor: root.theme.accentText
                    bordered: false
                    clickable: true
                    tooltip: "Open DOI"
                    onClicked: root.app.openExternal("https://doi.org/" + root.ref.fields.doi)
                }
                Chip {
                    theme: root.theme
                    visible: root.arxiv !== ""
                    text: "arXiv " + root.arxiv
                    textColor: root.theme.accentText
                    bordered: false
                    clickable: true
                    tooltip: "Open on arXiv"
                    onClicked: root.app.openExternal("https://arxiv.org/abs/" + root.arxiv)
                }
                Chip {
                    theme: root.theme
                    text: root.ref ? root.ref.citekey : ""
                    trailingIcon: "copy"
                    clickable: true
                    tooltip: "Copy citation key"
                    onClicked: root.app.copy(root.ref.citekey)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: root.theme.space(6)
                spacing: root.theme.space(2)
                IconButton { theme: root.theme; icon: "pdf"; iconSize: root.theme.title + 3; tooltip: "Open PDF"; shortcut: root.app.pdfShortcut; busy: root.app.pdfBusy; onClicked: root.app.getPdf() }
                IconButton { theme: root.theme; icon: "external"; iconSize: root.theme.title + 3; tooltip: "Open link"; shortcut: "Ctrl+U"; onClicked: root.app.openLink() }
                IconButton { theme: root.theme; icon: "notePlus"; iconSize: root.theme.title + 3; tooltip: "New note"; onClicked: root.app.edit("note", null) }
                IconButton {
                    theme: root.theme
                    visible: root.arxiv !== ""
                    icon: "sparkles"
                    iconSize: root.theme.title + 3
                    iconColor: root.theme.accentText
                    active: root.app.detailTab === "ai"
                    tooltip: "AI overview"; shortcut: "Ctrl+2"
                    onClicked: root.app.selectTab("ai")
                }
                IconButton { theme: root.theme; icon: "terminal"; iconSize: root.theme.title + 3; tooltip: "Chat about this in " + root.app.cliName; busy: root.app.codexBusy; onClicked: root.app.openCodex(false) }
                IconButton { theme: root.theme; icon: "chat"; iconSize: root.theme.title + 3; tooltip: "Chat about this in " + root.app.desktopName; enabled: !root.app.codexBusy; onClicked: root.app.openCodex(true) }
                Rectangle { implicitWidth: 1; implicitHeight: root.theme.space(16); color: root.theme.line; Layout.leftMargin: root.theme.space(6); Layout.rightMargin: root.theme.space(6) }
                Repeater {
                    model: root.ref && root.ref.projects ? root.ref.projects.slice(0, 3) : []
                    Chip { required property var modelData; theme: root.theme; icon: "folder"; text: modelData.name; textColor: root.theme.muted }
                }
                Chip {
                    theme: root.theme
                    icon: "plus"
                    text: "project"
                    bordered: false
                    clickable: true
                    textColor: root.theme.dim
                    iconColor: root.theme.dim
                    tooltip: "Assign to project"
                    visible: root.app.projects.length > 0
                    onClicked: root.app.assign()
                }
                Item { Layout.fillWidth: true }
                IconButton {
                    id: overflow
                    objectName: "overflowButton"
                    theme: root.theme
                    icon: "dots"
                    iconSize: root.theme.heading + 2
                    tooltip: "More"
                    active: root.app.overflowOpen
                    activeColor: root.theme.bright
                    onClicked: root.app.openOverflowMenu(overflow)
                }
                IconButton {
                    theme: root.theme
                    icon: "close"
                    iconSize: root.theme.title + 1
                    iconColor: root.theme.dim
                    tooltip: "Hide details"
                    onClicked: root.app.collapseDetail()
                }
            }
        }

        SegmentedTabs {
            Layout.fillWidth: true
            Layout.topMargin: root.theme.space(12)
            Layout.leftMargin: root.theme.space(24)
            theme: root.theme
            current: root.app.detailTab
            tabs: [
                {key: "overview", label: "Overview"},
                {key: "ai", label: "AI summary", icon: "sparkles", visible: root.arxiv !== ""},
                {key: "notes", label: "Notes", count: root.ref && root.ref.notes ? root.ref.notes.length + (root.ref.next_note_cursor !== null && root.ref.next_note_cursor !== undefined ? "+" : "") : 0},
                {key: "files", label: "Files", count: root.ref && root.ref.attachments ? root.ref.attachments.length : 0},
                {key: "bibtex", label: "BibTeX"}
            ]
            onSelected: key => root.app.selectTab(key)
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: Math.max(0, root.tabKeys.indexOf(root.app.detailTab))
            OverviewTab { theme: root.theme; app: root.app }
            AiSummaryTab { theme: root.theme; app: root.app }
            NotesTab { theme: root.theme; app: root.app }
            FilesTab { theme: root.theme; app: root.app }
            BibtexTab { theme: root.theme; app: root.app }
        }
    }

    EmptyState {
        theme: root.theme
        anchors.centerIn: parent
        visible: !root.ref
        icon: "book"
        iconColor: root.theme.muted
        title: root.app.hits.length ? "Loading…" : "Nothing selected"
        hint: root.app.hits.length ? "" : "Search on the left, or press + to add a reference"
    }
}
