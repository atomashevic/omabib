import QtQuick
import QtQuick.Layouts

// The first thing a new library shows: the ways to fill it. Moving from
// Zotero comes first and says what it found when Zotero is on this computer;
// then a BibTeX file from any other manager, a first paper, the agents that
// can use the library (App.qml connects the ones it finds as this page first
// shows), and sync for a library that already lives on another computer.
ColumnLayout {
    id: root

    required property var theme
    required property var app

    readonly property var info: app.zotero || ({})
    readonly property bool zoteroFound: info.found === true
    readonly property var mine: (info.libraries || []).filter(function (l) { return !l.group })[0] || ({})
    readonly property var agents: (app.settingsInfo || {}).agents || []
    readonly property var connected: agents.filter(function (a) { return a.state === "connected" }).map(function (a) { return a.name })
    readonly property var installed: agents.filter(function (a) { return a.state !== "unavailable" })

    spacing: theme.space(14)

    // "A", "A and B", "A, B and C".
    function names(list) { return list.length < 2 ? list.join("") : list.slice(0, -1).join(", ") + " and " + list[list.length - 1] }
    function count(n, word) { return Number(n || 0).toLocaleString(Qt.locale("en_US"), "f", 0) + " " + word + (n === 1 ? "" : "s") }

    component Way: Rectangle {
        id: way
        property string icon: ""
        property string title: ""
        property string detail: ""
        property bool highlighted: false
        default property alias actions: buttons.data
        Layout.fillWidth: true
        implicitHeight: wayRow.implicitHeight + root.theme.space(28)
        radius: root.theme.radiusLarge
        color: root.theme.raised
        border.width: highlighted ? 2 : 1
        border.color: highlighted ? root.theme.accent : root.theme.line
        RowLayout {
            id: wayRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(16); rightMargin: root.theme.space(16) }
            spacing: root.theme.space(14)
            Rectangle {
                Layout.alignment: Qt.AlignTop
                implicitWidth: root.theme.space(36); implicitHeight: implicitWidth
                radius: width / 2
                color: root.theme.side
                border.width: 1
                border.color: root.theme.line
                Icon { theme: root.theme; anchors.centerIn: parent; name: way.icon; size: root.theme.title + 3; color: root.theme.accentText }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(3)
                Text { Layout.fillWidth: true; text: way.title; color: root.theme.bright; font.family: root.theme.sans; font.pixelSize: root.theme.subtitle; font.weight: Font.DemiBold; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                Text { Layout.fillWidth: true; visible: text !== ""; text: way.detail; color: root.theme.muted; font.family: root.theme.sans; font.pixelSize: root.theme.body; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                Flow { id: buttons; Layout.fillWidth: true; Layout.topMargin: root.theme.space(6); spacing: root.theme.space(8) }
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.bottomMargin: root.theme.space(4)
        spacing: root.theme.space(6)
        Text { Layout.fillWidth: true; text: "Welcome to Omabib"; color: root.theme.bright; font.family: root.theme.sans; font.pixelSize: root.theme.heading; font.weight: Font.DemiBold; wrapMode: Text.Wrap; textFormat: Text.PlainText }
        Text { Layout.fillWidth: true; text: "Bring in the papers you already have, or start with one."; color: root.theme.muted; font.family: root.theme.sans; font.pixelSize: root.theme.subtitle; wrapMode: Text.Wrap; textFormat: Text.PlainText }
    }

    Way {
        objectName: "welcomeZotero"
        icon: "book"
        highlighted: root.zoteroFound
        title: root.zoteroFound ? "Move your Zotero library" : "Coming from Zotero?"
        detail: root.app.zoteroLooking ? "Looking for Zotero on this computer…"
            : root.zoteroFound ? "Omabib found " + root.count(root.mine.references, "reference") + (root.mine.pdfs ? " and " + root.count(root.mine.pdfs, "PDF") : "") + " in Zotero. Citation keys, notes, highlights and collections come along, and Zotero isn't changed."
            : "Bring its references, PDFs, notes and collections straight from its library, citation keys included."
        TextButton {
            objectName: "welcomeZoteroButton"
            theme: root.theme
            variant: root.zoteroFound ? "primary" : "outline"
            icon: root.zoteroFound ? "download" : "folder"
            text: root.zoteroFound ? "Import from Zotero…" : "Find Zotero library…"
            onClicked: root.zoteroFound ? root.app.openZotero() : root.app.chooseZoteroFolder()
        }
    }
    Way {
        objectName: "welcomeBibtex"
        icon: "braces"
        title: "Import a BibTeX file"
        detail: "Export one from Mendeley, EndNote, JabRef, Paperpile or any other reference manager."
        TextButton { objectName: "welcomeBibtexButton"; theme: root.theme; icon: "file"; text: "Choose .bib file…"; onClicked: root.app.openBibPicker() }
    }
    Way {
        objectName: "welcomeAdd"
        icon: "plus"
        title: "Add a paper"
        detail: "Paste a DOI, arXiv ID or link, or drop PDFs anywhere on this window. Omabib finds the details, the abstract and an open-access PDF."
        TextButton { theme: root.theme; variant: root.zoteroFound ? "outline" : "primary"; icon: "plus"; text: "Add"; onClicked: root.app.edit("quick") }
        TextButton { objectName: "welcomeAddPdfButton"; theme: root.theme; icon: "pdf"; text: "Add PDF…"; onClicked: root.app.openPdfPicker() }
    }
    Way {
        objectName: "welcomeAgents"
        icon: "robot"
        title: root.connected.length ? "Your agents can use this library" : "Use this library from your agents"
        detail: root.app.agentsConnecting ? "Connecting the agents on this computer…"
            : root.connected.length ? root.names(root.connected) + " can search it, read its papers and notes, and save notes when you ask. A new session of each loads Omabib's tools."
            : root.installed.length ? "Connect " + root.names(root.installed.map(function (a) { return a.name })) + " in Settings to use the library outside Omabib."
            : "Install Claude Code or Codex and connect it in Settings. Omabib's own chat uses it too."
        Repeater {
            model: root.agents
            Chip {
                required property var modelData
                objectName: "welcomeAgent:" + modelData.id
                theme: root.theme
                readonly property bool trouble: modelData.state === "error" || modelData.state === "custom"
                icon: modelData.state === "connected" ? "check" : trouble ? "alert" : ""
                iconColor: modelData.state === "connected" ? root.theme.accentText : root.theme.urgent
                textColor: modelData.state === "connected" || trouble ? root.theme.text : root.theme.muted
                text: modelData.name + (modelData.state === "unavailable" ? " · not installed" : modelData.state === "missing" ? " · not connected" : "")
                tooltip: modelData.message || ""
            }
        }
        TextButton { objectName: "welcomeAgentSettings"; theme: root.theme; variant: "ghost"; text: "Agent settings"; onClicked: root.app.openSettings() }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: root.theme.space(2)
        spacing: root.theme.space(6)
        Icon { theme: root.theme; name: "cloudSync"; size: root.theme.title; color: root.theme.muted }
        Text { text: "Already using Omabib on another computer?"; color: root.theme.muted; font.family: root.theme.sans; font.pixelSize: root.theme.body; textFormat: Text.PlainText }
        TextButton { objectName: "welcomeSyncButton"; theme: root.theme; variant: "ghost"; text: "Set up sync"; onClicked: root.app.openSync() }
        Item { Layout.fillWidth: true }
    }
}
