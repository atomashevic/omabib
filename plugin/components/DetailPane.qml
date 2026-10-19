import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

// The selected reference: title, authors and identifiers, the actions, then
// the tabs.
Rectangle {
    id: root

    required property var theme
    required property var app

    readonly property var ref: app.selected
    readonly property string arxiv: Format.arxivId(ref)
    readonly property var tabKeys: ["overview", "ai", "notes", "files", "bibtex", "chat"]
    readonly property string agentName: app.chatAgent === "codex" ? "Codex" : "Claude"

    color: theme.card

    // A tab built the first time it shows, then kept, so start-up builds only
    // the tab in view.
    component LazyTab: Loader {
        readonly property bool current: StackLayout.isCurrentItem
        property bool used: false
        onCurrentChanged: if (current) used = true
        Component.onCompleted: if (current) used = true
        active: used
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        visible: !!root.ref
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: root.theme.space(32)
            Layout.rightMargin: root.theme.space(24)
            Layout.topMargin: root.theme.space(24)
            spacing: root.theme.space(10)

            RowLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(12)
                Text {
                    Layout.fillWidth: true
                    Layout.maximumWidth: root.theme.space(840)
                    text: root.ref ? (root.ref.title || root.ref.citekey) : ""
                    color: root.theme.bright
                    font.family: root.theme.readingFamily
                    font.pixelSize: root.theme.reading === "serif" ? root.theme.heading + 5 : root.theme.heading + 2
                    font.weight: Font.DemiBold
                    font.letterSpacing: root.theme.reading === "serif" ? 0 : -0.3
                    lineHeight: 1.18
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                IconButton {
                    Layout.alignment: Qt.AlignTop
                    theme: root.theme
                    visible: !root.app.inPaperTab
                    icon: "close"
                    iconSize: root.theme.title + 1
                    iconColor: root.theme.dim
                    tooltip: "Hide details"
                    onClicked: root.app.collapseDetail()
                }
                IconButton {
                    Layout.alignment: Qt.AlignTop
                    theme: root.theme
                    visible: root.app.inPaperTab
                    icon: "search"
                    iconSize: root.theme.title + 1
                    iconColor: root.theme.dim
                    tooltip: "Show in library"
                    onClicked: root.app.findInLibrary()
                }
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.ref ? Format.fullAuthors(root.ref.authors, 8) : ""
                color: root.theme.muted
                font.family: root.theme.sans
                font.pixelSize: root.theme.body + 0.5
                lineHeight: 1.15
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Flow {
                Layout.fillWidth: true
                spacing: root.theme.space(8)
                Chip {
                    theme: root.theme
                    visible: root.arxiv !== ""
                    accent: true
                    text: "arXiv " + root.arxiv
                    clickable: true
                    tooltip: "Open on arXiv"
                    onClicked: root.app.openExternal("https://arxiv.org/abs/" + root.arxiv)
                }
                Chip {
                    theme: root.theme
                    visible: !!(root.ref && root.ref.fields && root.ref.fields.doi) && root.arxiv === ""
                    accent: true
                    text: root.ref && root.ref.fields ? (root.ref.fields.doi || "") : ""
                    clickable: true
                    tooltip: "Open DOI"
                    onClicked: root.app.openExternal("https://doi.org/" + root.ref.fields.doi)
                }
                Chip {
                    theme: root.theme
                    mono: true
                    text: root.ref ? root.ref.citekey : ""
                    textColor: root.theme.muted
                    trailingIcon: "copy"
                    clickable: true
                    tooltip: "Copy citation key"
                    onClicked: root.app.copy(root.ref.citekey)
                }
                Text {
                    height: root.theme.space(24)
                    verticalAlignment: Text.AlignVCenter
                    visible: text !== ""
                    text: root.ref ? [Format.venue(root.ref), root.ref.year].filter(function (s) { return !!s }).join(" · ") : ""
                    color: root.theme.muted
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                    textFormat: Text.PlainText
                }
            }

            Flow {
                Layout.fillWidth: true
                Layout.topMargin: root.theme.space(6)
                spacing: root.theme.space(8)
                TextButton {
                    objectName: "openPdfButton"
                    theme: root.theme
                    variant: "primary"
                    icon: "pdf"
                    text: "Open PDF"
                    shortcut: root.app.pdfShortcut
                    busy: root.app.pdfBusy
                    onClicked: root.app.getPdf()
                }
                TextButton {
                    id: cite
                    objectName: "citeButton"
                    theme: root.theme
                    icon: "quote"
                    text: "Cite"
                    onClicked: root.app.openCiteMenu(cite)
                }
                TextButton {
                    theme: root.theme
                    icon: "sparkles"
                    text: "Ask " + root.agentName
                    onClicked: root.app.focusChat()
                }
                TextButton {
                    theme: root.theme
                    visible: root.app.projects.length > 0
                    icon: "folderPlus"
                    text: "Add to project"
                    onClicked: root.app.assign()
                }
                IconButton {
                    id: overflow
                    objectName: "overflowButton"
                    theme: root.theme
                    icon: "dots"
                    size: root.theme.space(30)
                    iconSize: root.theme.title + 2
                    iconColor: root.theme.muted
                    tooltip: "More"
                    active: root.app.overflowOpen
                    onClicked: root.app.openOverflowMenu(overflow)
                }
            }
        }

        SegmentedTabs {
            Layout.fillWidth: true
            Layout.topMargin: root.theme.space(18)
            Layout.leftMargin: root.theme.space(32)
            Layout.rightMargin: root.theme.space(24)
            theme: root.theme
            current: root.app.detailTab
            tabs: [
                {key: "overview", label: "Overview"},
                {key: "ai", label: "AI summary", icon: "sparkles", visible: root.arxiv !== ""},
                {key: "notes", label: "Notes", count: root.ref && root.ref.notes ? root.ref.notes.length + (root.ref.next_note_cursor !== null && root.ref.next_note_cursor !== undefined ? "+" : "") : 0},
                {key: "files", label: "Files", count: root.ref && root.ref.attachments ? root.ref.attachments.length : 0},
                {key: "bibtex", label: "BibTeX"},
                {key: "chat", label: "Chat"}
            ]
            onSelected: key => root.app.selectTab(key)
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: Math.max(0, root.tabKeys.indexOf(root.app.detailTab))
            LazyTab { sourceComponent: OverviewTab { theme: root.theme; app: root.app } }
            LazyTab { sourceComponent: AiSummaryTab { theme: root.theme; app: root.app } }
            LazyTab { sourceComponent: NotesTab { theme: root.theme; app: root.app } }
            LazyTab { sourceComponent: FilesTab { theme: root.theme; app: root.app } }
            LazyTab { sourceComponent: BibtexTab { theme: root.theme; app: root.app } }
            LazyTab { sourceComponent: ChatPane { theme: root.theme; app: root.app } }
        }
    }

    EmptyState {
        theme: root.theme
        anchors.centerIn: parent
        visible: !root.ref
        icon: "book"
        iconColor: root.theme.muted
        title: root.app.inPaperTab || root.app.hits.length ? "Loading…" : "Nothing selected"
        hint: root.app.inPaperTab || root.app.hits.length ? "" : "Search in the toolbar, or press Add to bring in a reference"
    }
}
