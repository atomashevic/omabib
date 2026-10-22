import QtQuick
import QtQuick.Layouts

// Moving a Zotero library in: what Omabib found, the few choices that
// matter, then progress and what came over. App.qml owns the service calls
// (`app.zotero` from zotero_detect, `app.zoteroOptions`, the import's
// `app.zoteroProgress` and `app.zoteroResult`).
ColumnLayout {
    id: root

    required property var theme
    required property var app

    readonly property var info: app.zotero || ({})
    readonly property var options: app.zoteroOptions
    readonly property var groups: (info.libraries || []).filter(function (l) { return l.group && l.references > 0 })
    // The libraries the import would include.
    readonly property var included: (info.libraries || []).filter(function (l) { return !l.group || options.groups })
    readonly property int references: sum("references")
    readonly property bool canImport: page === "found" && references > 0
    readonly property string countText: count(references, "reference")
    readonly property string page: app.zoteroResult ? "done"
        : app.zoteroImporting ? "importing"
        : app.zoteroLooking ? "looking"
        : app.zoteroError !== "" ? "error"
        : info.found === true ? "found"
        : info.found === false ? "missing"
        : "looking"

    spacing: theme.space(8)

    function sum(key) {
        var n = 0
        for (var i = 0; i < included.length; i++) n += included[i][key] || 0
        return n
    }
    function count(n, word) { return Number(n || 0).toLocaleString(Qt.locale("en_US"), "f", 0) + " " + word + (n === 1 ? "" : "s") }
    function size(bytes) {
        if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + " GB"
        if (bytes >= 1e6) return Math.round(bytes / 1e6) + " MB"
        return Math.max(1, Math.round(bytes / 1e3)) + " KB"
    }
    function home(path) {
        var h = root.app.homeDir
        return h && String(path).indexOf(h) === 0 ? "~" + String(path).slice(h.length) : String(path || "")
    }

    component Line: Text {
        Layout.fillWidth: true
        color: root.theme.text
        font.family: root.theme.sans
        font.pixelSize: root.theme.body
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    component Hint: Text {
        Layout.fillWidth: true
        color: root.theme.dim
        font.family: root.theme.sans
        font.pixelSize: root.theme.small
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    // A fact with an icon: "1,962 references", "1,470 PDFs (3.9 GB)".
    component Fact: RowLayout {
        id: fact
        property string icon: "check"
        property string text: ""
        property string detail: ""
        property bool warn: false
        Layout.fillWidth: true
        spacing: root.theme.space(10)
        Icon { theme: root.theme; name: fact.icon; size: root.theme.title + 1; color: fact.warn ? root.theme.urgent : root.theme.accentText; Layout.alignment: Qt.AlignTop; Layout.topMargin: 1 }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text { Layout.fillWidth: true; text: fact.text; color: root.theme.bright; font.family: root.theme.sans; font.pixelSize: root.theme.body; wrapMode: Text.Wrap; textFormat: Text.PlainText }
            Text { Layout.fillWidth: true; visible: text !== ""; text: fact.detail; color: root.theme.muted; font.family: root.theme.sans; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText }
        }
    }
    // A radio or a checkbox row with a line of detail.
    component Choice: Rectangle {
        id: choice
        property string label: ""
        property string detail: ""
        property bool checked: false
        property bool radio: false
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: choiceRow.implicitHeight + root.theme.space(12)
        radius: root.theme.radius
        color: choiceMouse.containsMouse ? root.theme.hoverFill : "transparent"
        RowLayout {
            id: choiceRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(8); rightMargin: root.theme.space(8) }
            spacing: root.theme.space(10)
            Icon {
                theme: root.theme
                name: choice.radio ? (choice.checked ? "radioOn" : "radioOff") : (choice.checked ? "checkboxMarked" : "checkboxBlank")
                size: root.theme.title + 1
                color: choice.checked ? root.theme.accentText : root.theme.muted
                Layout.alignment: Qt.AlignTop
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text { Layout.fillWidth: true; text: choice.label; color: choice.checked ? root.theme.bright : root.theme.text; font.family: root.theme.sans; font.pixelSize: root.theme.body; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                Text { Layout.fillWidth: true; visible: text !== ""; text: choice.detail; color: root.theme.dim; font.family: root.theme.sans; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText }
            }
        }
        MouseArea { id: choiceMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: choice.toggled() }
    }

    // Looking.
    RowLayout {
        visible: root.page === "looking"
        Layout.fillWidth: true
        spacing: root.theme.space(10)
        Icon { theme: root.theme; name: "refresh"; size: root.theme.title + 1; color: root.theme.accentText; RotationAnimation on rotation { running: root.page === "looking"; from: 0; to: 360; duration: 900; loops: Animation.Infinite } }
        Line { text: "Looking for your Zotero library…"; color: root.theme.muted }
    }

    // Nothing found where Zotero keeps it.
    ColumnLayout {
        objectName: "zoteroMissing"
        visible: root.page === "missing"
        Layout.fillWidth: true
        spacing: root.theme.space(8)
        Line { text: "Omabib didn't find a Zotero library in ~/Zotero or where Zotero's settings point." }
        Hint { text: "In Zotero, Settings → Advanced → Files and Folders shows the data directory. Choose the zotero.sqlite file in it." }
        RowLayout {
            Layout.topMargin: root.theme.space(4)
            TextButton { theme: root.theme; variant: "primary"; icon: "folder"; text: "Find Zotero library…"; onClicked: root.app.chooseZoteroFolder() }
        }
    }

    ColumnLayout {
        visible: root.page === "error"
        Layout.fillWidth: true
        spacing: root.theme.space(8)
        Fact { icon: "alert"; warn: true; text: root.app.zoteroError }
        RowLayout {
            TextButton { theme: root.theme; icon: "refresh"; text: "Try again"; onClicked: root.app.detectZotero(root.info.found ? root.info.path : "") }
            TextButton { theme: root.theme; variant: "ghost"; icon: "folder"; text: "Find Zotero library…"; onClicked: root.app.chooseZoteroFolder() }
        }
    }

    // What would come over, and the choices.
    ColumnLayout {
        objectName: "zoteroFound"
        visible: root.page === "found"
        Layout.fillWidth: true
        spacing: root.theme.space(10)
        Hint { text: "From " + root.home(root.info.path) + ". Zotero itself isn't changed." }
        Fact {
            visible: !!root.info.running
            icon: "alert"
            text: "Zotero is open"
            detail: "That's fine: Omabib reads a copy of its library. Anything you change in Zotero from now on won't come over until you import again."
        }
        Fact {
            icon: "book"
            text: root.count(root.references, "reference")
            detail: root.sum("citation_keys") > 0 ? root.count(root.sum("citation_keys"), "citation key") + " stay as they are, so your LaTeX and Pandoc citations keep working" : ""
        }
        Fact {
            visible: root.sum("pdfs") + root.sum("pdfs_missing") > 0
            icon: "pdf"
            text: root.count(root.sum("pdfs"), "PDF") + " (" + root.size(root.sum("pdf_bytes")) + ")"
            detail: root.sum("pdfs_missing") > 0 ? Number(root.sum("pdfs_missing")).toLocaleString(Qt.locale("en_US"), "f", 0) + " more aren't on this computer yet: Zotero downloads some files only when you open them" : ""
        }
        Fact {
            visible: root.options.notes && root.sum("notes") + root.sum("annotations") > 0
            icon: "note"
            text: root.count(root.sum("notes"), "note") + " and " + root.count(root.sum("annotations"), "highlight") + " and comment" + (root.sum("annotations") === 1 ? "" : "s")
            detail: "Highlights are gathered into one note per PDF, with their pages"
        }
        Fact {
            visible: root.options.projects && (root.options.groups ? root.info.projects : root.info.projects_own) > 0
            icon: "folder"
            text: root.count(root.options.groups ? root.info.projects : root.info.projects_own, "collection") + " become projects"
        }

        SectionLabel { theme: root.theme; text: "PDFs"; Layout.topMargin: root.theme.space(6) }
        Choice {
            radio: true
            checked: root.options.pdfs !== "link"
            label: "Copy into Omabib"
            detail: root.size(root.sum("pdf_bytes")) + " more on disk. Your library no longer depends on Zotero, and sync can carry the files."
            onToggled: root.app.setZoteroOption("pdfs", "copy")
        }
        Choice {
            objectName: "zoteroLink"
            radio: true
            checked: root.options.pdfs === "link"
            label: "Use Zotero's files where they are"
            detail: "No extra space, but keep the Zotero folder: removing it would break the links."
            onToggled: root.app.setZoteroOption("pdfs", "link")
        }

        SectionLabel { theme: root.theme; text: "Bring along"; Layout.topMargin: root.theme.space(6) }
        Choice {
            checked: root.options.notes
            label: "Notes and highlights"
            onToggled: root.app.setZoteroOption("notes", !root.options.notes)
        }
        Choice {
            checked: root.options.projects
            label: "Collections as projects"
            detail: "Subcollections become projects named “Parent / Child”."
            onToggled: root.app.setZoteroOption("projects", !root.options.projects)
        }
        Choice {
            objectName: "zoteroGroups"
            visible: root.groups.length > 0
            checked: root.options.groups
            label: "Group libraries"
            detail: root.groups.map(function (g) { return g.name + " (" + Number(g.references).toLocaleString(Qt.locale("en_US"), "f", 0) + ")" }).join(", ")
            onToggled: root.app.setZoteroOption("groups", !root.options.groups)
        }
        Hint {
            Layout.topMargin: root.theme.space(4)
            text: "References already in Omabib are filled in, not added twice, so it's safe to import again later to bring over what's new."
        }
    }

    // Under way.
    ColumnLayout {
        objectName: "zoteroImporting"
        visible: root.page === "importing"
        Layout.fillWidth: true
        spacing: root.theme.space(10)
        readonly property var p: root.app.zoteroProgress || ({})
        Line { text: (parent.p.what || "Starting") + (parent.p.total ? " · " + Number(parent.p.done).toLocaleString(Qt.locale("en_US"), "f", 0) + " of " + Number(parent.p.total).toLocaleString(Qt.locale("en_US"), "f", 0) : "…") }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: root.theme.space(6)
            radius: height / 2
            color: root.theme.line
            Rectangle {
                width: parent.parent.p.total ? parent.width * Math.min(1, parent.parent.p.done / parent.parent.p.total) : 0
                height: parent.height
                radius: parent.radius
                color: root.theme.accent
                Behavior on width { NumberAnimation { duration: 200 } }
            }
        }
        Hint { text: "You can hide this window; the import carries on and says when it's done." }
    }

    // Done.
    ColumnLayout {
        objectName: "zoteroDone"
        visible: root.page === "done"
        Layout.fillWidth: true
        spacing: root.theme.space(10)
        readonly property var r: root.app.zoteroResult || ({})
        Line { text: "Your Zotero library is here."; color: root.theme.bright; font.pixelSize: root.theme.subtitle; font.weight: Font.DemiBold }
        Fact {
            icon: "book"
            text: parent.r.references ? root.count(parent.r.references, "reference") + " added" : "No new references"
            detail: parent.r.merged ? root.count(parent.r.merged, "reference") + " already in Omabib were filled in" : ""
        }
        Fact {
            visible: parent.r.already > 0
            icon: "check"
            text: root.count(parent.r.already, "reference") + " came over in an earlier import"
            detail: parent.r.deleted ? root.count(parent.r.deleted, "reference") + " you deleted in Omabib since stay deleted" : ""
        }
        Fact { visible: parent.r.pdfs > 0; icon: "pdf"; text: root.count(parent.r.pdfs, "PDF") + (parent.r.pdfs_copied ? " copied" : " linked") }
        Fact { visible: parent.r.notes > 0; icon: "note"; text: root.count(parent.r.notes, "note") }
        Fact { visible: parent.r.project_links > 0; icon: "folder"; text: root.count(parent.r.projects, "new project") + ", " + root.count(parent.r.project_links, "reference") + " in projects" }
        Fact {
            visible: parent.r.pdfs_missing > 0
            icon: "fileMissing"
            warn: true
            text: root.count(parent.r.pdfs_missing, "PDF") + " didn't come over"
            detail: "They weren't on this computer, or weren't really PDFs. Open them in Zotero so it downloads them, then import again."
        }
        Fact {
            visible: parent.r.standalone > 0
            icon: "file"
            text: root.count(parent.r.standalone, "PDF") + " without a Zotero item"
            detail: "Each became a reference named after its file. Use Fill metadata online on them."
        }
        Hint {
            visible: (parent.r.other_files || 0) + (parent.r.loose_notes || 0) > 0
            text: "Left in Zotero: " + [parent.r.other_files ? root.count(parent.r.other_files, "non-PDF file") : "", parent.r.loose_notes ? root.count(parent.r.loose_notes, "standalone note") : ""].filter(function (s) { return s }).join(" and ") + "."
        }
    }
}
