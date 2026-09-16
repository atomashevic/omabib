import QtQuick
import QtQuick.Layouts
import "Format.js" as Format
import "Markdown.js" as Markdown

// Contextual notes as cards: scope, page, the note itself rendered as Markdown
// (with math and code blocks), its labels and a thumbnail of the PDF clip it
// was taken from.
ScrollPane {
    id: root

    required property var app
    readonly property var ref: app.selected
    readonly property var notes: ref && ref.notes ? ref.notes : []
    readonly property var style: theme.markdownStyle(theme.card)

    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(12)
        Text {
            text: root.notes.length === 1 ? "1 note" : root.notes.length + " notes"
            color: root.theme.muted
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
        }
        RowLayout {
            // Shrinks first when the Notes tab sits in a reader's narrow side pane.
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            spacing: root.theme.space(6)
            Icon {
                theme: root.theme
                name: root.app.includeOtherNotes ? "checkboxMarked" : "checkboxBlank"
                size: root.theme.title
                color: root.app.includeOtherNotes ? root.theme.accentText : root.theme.muted
            }
            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "Other projects’ notes" + (root.ref && root.ref.other_project_note_count !== undefined ? " (" + root.ref.other_project_note_count + ")" : "")
                color: root.theme.muted
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            TapHandler { onTapped: root.app.toggleOtherNotes() }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
        TextButton { theme: root.theme; icon: "notePlus"; text: "New note"; onClicked: root.app.edit("note", null) }
    }

    EmptyState {
        theme: root.theme
        Layout.fillWidth: true
        Layout.topMargin: root.theme.space(48)
        visible: root.notes.length === 0
        icon: "note"
        iconColor: root.theme.muted
        title: "No notes yet"
        hint: "Notes you take while reading, with their page and clip, collect here."
    }

    Repeater {
        model: root.notes
        Rectangle {
            id: card
            required property var modelData
            readonly property var image: root.app.noteImages[modelData.id]
            property bool expandedClip: false
            readonly property var blocks: Markdown.blocks(modelData.body || "")
            Layout.fillWidth: true
            implicitHeight: noteColumn.implicitHeight + root.theme.space(24)
            color: root.theme.app
            border.width: 1
            border.color: root.theme.line
            radius: root.theme.radius

            Component.onCompleted: if (modelData.image) root.app.loadNoteImage(modelData)
            onBlocksChanged: root.app.ensureMath(Markdown.mathKeys(blocks))

            ColumnLayout {
                id: noteColumn
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(12); leftMargin: root.theme.space(14); rightMargin: root.theme.space(8) }
                spacing: root.theme.space(10)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    Chip { theme: root.theme; icon: card.modelData.project_id ? "folder" : "globe"; text: card.modelData.project_name || "Global" }
                    Chip {
                        theme: root.theme
                        visible: !!card.modelData.evidence
                        icon: /^PDF\b/i.test(card.modelData.evidence || "") ? "pdf" : "tag"
                        text: Format.evidenceLabel(card.modelData.evidence)
                        tooltip: card.modelData.evidence || ""
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: Format.relativeTime(card.modelData.updated_at || card.modelData.created_at) + " · " + card.modelData.provenance + (card.modelData.revision > 1 ? " · rev " + card.modelData.revision : "")
                        color: root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    IconButton { theme: root.theme; icon: "pencil"; size: root.theme.space(24); iconSize: root.theme.title; iconColor: root.theme.dim; tooltip: "Edit note"; onClicked: root.app.edit("note", card.modelData) }
                    IconButton { theme: root.theme; icon: "trash"; size: root.theme.space(24); iconSize: root.theme.title; iconColor: root.theme.dim; tooltip: "Delete note"; onClicked: root.app.requestNoteDelete(card.modelData.id) }
                }

                ReadingText {
                    objectName: "noteBody"
                    Layout.fillWidth: true
                    visible: card.blocks.length > 0
                    theme: root.theme
                    text: visible ? Markdown.toHtml(card.blocks, root.style, root.app.mathCache) : ""
                    onOpenLink: url => root.app.openExternal(url)
                }

                Flow {
                    Layout.fillWidth: true
                    visible: (card.modelData.labels || []).length > 0
                    spacing: root.theme.space(6)
                    Repeater {
                        model: card.modelData.labels || []
                        Chip { required property var modelData; theme: root.theme; icon: "tag"; text: modelData; bordered: false }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.maximumWidth: root.theme.space(640)
                    visible: !!card.modelData.image
                    implicitHeight: clip.status === Image.Ready
                        ? (card.expandedClip ? clip.implicitHeight * width / Math.max(1, clip.implicitWidth) : Math.min(root.theme.space(150), clip.implicitHeight * width / Math.max(1, clip.implicitWidth)))
                        : root.theme.space(60)
                    clip: true
                    Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: root.theme.line; z: 1 }
                    Image {
                        id: clip
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        source: card.image || ""
                        fillMode: Image.PreserveAspectFit
                        verticalAlignment: Image.AlignTop
                        asynchronous: true
                        cache: false
                        height: implicitHeight * width / Math.max(1, implicitWidth)
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: clip.status !== Image.Ready
                        text: "Loading clip…"
                        color: root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    TapHandler { onTapped: card.expandedClip = !card.expandedClip }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
            }
        }
    }

    TextButton {
        Layout.alignment: Qt.AlignHCenter
        theme: root.theme
        visible: !!root.ref && root.ref.next_note_cursor !== null && root.ref.next_note_cursor !== undefined
        variant: "ghost"
        icon: "chevronDown"
        text: "Load more notes"
        onClicked: root.app.loadMoreNotes()
    }
}
