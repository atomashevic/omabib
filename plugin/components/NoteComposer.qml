import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Writes a note inside a reader tab's side pane, beside the page it is about:
// a new note, a page note, a clip of a region, or an edit of an existing note.
// App.qml owns the draft (`app.composer`) and saves it with `saveComposer`.
FocusScope {
    id: root

    required property var theme
    required property var app

    // {note, clip: {source_pdf, page, rect_pt?, preview?}, token, projectId, labels, evidence}
    readonly property var draft: app.composer
    readonly property bool isClip: !!(draft && !draft.note && draft.clip && draft.clip.rect_pt)

    onDraftChanged: {
        if (!draft) return
        editor.text = draft.note ? draft.note.body : (draft.body || "")
        labels.text = draft.labels || ""
        evidence.text = draft.evidence || ""
        var at = 0
        for (var i = 0; i < app.projects.length; i++) if (app.projects[i].id === draft.projectId) at = i + 1
        scope.currentIndex = at
        Qt.callLater(function () { if (root.draft) editor.forceActiveFocus() })
    }

    function save() {
        if (!draft || app.composerSaving) return
        var projectId = scope.currentIndex > 0 ? app.projects[scope.currentIndex - 1].id : null
        app.saveComposer(editor.text, projectId, labels.text, evidence.text)
    }

    Keys.onEscapePressed: app.cancelComposer()
    Shortcut { sequence: "Ctrl+Return"; enabled: root.visible && !!root.draft; onActivated: root.save() }

    component Field: TextField {
        id: field
        Layout.fillWidth: true
        implicitHeight: root.theme.space(30)
        color: root.theme.bright
        placeholderTextColor: root.theme.dim
        selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.55)
        selectedTextColor: root.theme.bright
        font.family: root.theme.mono
        font.pixelSize: root.theme.small
        leftPadding: root.theme.space(8)
        selectByMouse: true
        background: Rectangle {
            color: root.theme.app
            radius: root.theme.radius
            border.width: field.activeFocus ? root.theme.focusBorderWidth : 1
            border.color: field.activeFocus ? root.theme.focusBorder : root.theme.line
        }
    }

    ColumnLayout {
        anchors { fill: parent; margins: root.theme.space(14) }
        spacing: root.theme.space(8)

        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(6)
            Icon {
                theme: root.theme
                name: root.draft && root.draft.note ? "pencil" : root.isClip ? "crop" : "notePlus"
                size: root.theme.title
                color: root.theme.accentText
            }
            Text {
                Layout.fillWidth: true
                text: !root.draft ? "" : root.draft.note ? "Edit note"
                    : (root.isClip ? "Clip" : "Note") + (root.draft.clip ? "  ·  p. " + root.draft.clip.page : "")
                color: root.theme.bright
                font.family: root.theme.mono
                font.pixelSize: root.theme.body
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            TextButton {
                objectName: "composerAskChat"
                visible: root.isClip
                theme: root.theme
                variant: "ghost"
                icon: "robot"
                text: "Ask chat"
                fontSize: root.theme.small
                onClicked: root.app.askAboutClip(root.draft.clip)
            }
            IconButton { theme: root.theme; icon: "close"; size: root.theme.space(24); iconSize: root.theme.title; iconColor: root.theme.dim; tooltip: "Discard"; shortcut: "Esc"; onClicked: root.app.cancelComposer() }
        }

        // The clipped region, cut from the page image on screen; the saved clip is rendered sharper.
        Rectangle {
            readonly property var preview: root.isClip ? root.draft.clip.preview : null
            visible: !!preview
            Layout.fillWidth: true
            Layout.preferredHeight: preview ? Math.min(root.theme.space(180), (width - root.theme.space(12)) * preview.rect.height / Math.max(1, preview.rect.width) + root.theme.space(12)) : 0
            color: "white"
            radius: root.theme.radius
            Image {
                objectName: "composerClipPreview"
                anchors { fill: parent; margins: root.theme.space(6) }
                source: parent.preview ? root.app.fileUrl(parent.preview.path) : ""
                sourceClipRect: parent.preview ? parent.preview.rect : Qt.rect(0, 0, 0, 0)
                fillMode: Image.PreserveAspectFit
                cache: false
                smooth: true
            }
        }

        NoteEditor {
            id: editor
            objectName: "composerEditor"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: root.theme.space(120)
            theme: root.theme
            app: root.app
            placeholderText: root.isClip ? "Add a comment on this clip…" : "What matters here?"
        }

        ComboBox {
            id: scope
            objectName: "composerScope"
            Layout.fillWidth: true
            implicitHeight: root.theme.space(30)
            model: ["Global · all projects"].concat(root.app.projects.map(function (p) { return p.name }))
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            contentItem: Text {
                leftPadding: root.theme.space(8)
                text: scope.displayText
                color: root.theme.bright
                font: scope.font
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            background: Rectangle {
                color: root.theme.app
                radius: root.theme.radius
                border.width: scope.activeFocus ? root.theme.focusBorderWidth : 1
                border.color: scope.activeFocus ? root.theme.focusBorder : root.theme.line
            }
        }
        Field { id: labels; placeholderText: "Labels, separated by commas" }
        Field { id: evidence; placeholderText: "Evidence location, e.g. PDF p. 7, Table 2" }

        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            Text {
                Layout.fillWidth: true
                text: root.app.composerError
                color: root.theme.urgent
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            TextButton { theme: root.theme; variant: "ghost"; text: "Cancel"; onClicked: root.app.cancelComposer() }
            TextButton {
                objectName: "composerSave"
                theme: root.theme
                variant: "primary"
                text: root.app.composerSaving ? "Saving…" : "Save"
                shortcut: "^↵"
                enabled: !root.app.composerSaving
                onClicked: root.save()
            }
        }
    }
}
