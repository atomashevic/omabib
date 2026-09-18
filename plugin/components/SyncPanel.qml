import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Format.js" as Format

// Sync: choose where the library lives, sign in, start or join the shared
// library, then see how syncing goes. App.qml owns the service calls
// (`app.syncStatus`, `app.syncProviders`, `app.syncFound`, `app.syncConflicts`).
ColumnLayout {
    id: root

    required property var theme
    required property var app

    readonly property var s: app.syncStatus || ({})
    readonly property var info: app.syncProviders || ({})
    readonly property var providers: info.providers || []
    readonly property bool rcloneReady: !!(info.rclone && info.rclone.installed)
    readonly property var connecting: s.connecting || null
    readonly property bool waiting: !!connecting && ["starting", "browser", "finishing"].indexOf(connecting.state) >= 0
    readonly property string page: s.configured ? "status" : waiting ? "connecting" : s.connected ? "found" : "choose"
    readonly property var found: app.syncFound
    readonly property string placeLabel: s.provider ? (s.provider.label === "Folder" ? "the folder" : s.provider.label) : ""
    // "folder" or "rclone" while one of those asks for more.
    property string choosing: ""

    spacing: theme.space(8)

    function providerIcon(id) {
        return ({drive: "googleDrive", dropbox: "dropbox", onedrive: "onedrive", folder: "folderSync", rclone: "server"})[id] || "cloudSync"
    }
    function count(n, word) { return Number(n || 0).toLocaleString(Qt.locale("en_US"), "f", 0) + " " + word + (n === 1 ? "" : "s") }

    component Hint: Text {
        Layout.fillWidth: true
        color: root.theme.dim
        font.family: root.theme.mono
        font.pixelSize: root.theme.small
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    component Line: Text {
        Layout.fillWidth: true
        color: root.theme.text
        font.family: root.theme.mono
        font.pixelSize: root.theme.body
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    component Field: TextField {
        Layout.fillWidth: true
        color: root.theme.bright
        placeholderTextColor: root.theme.dim
        font.family: root.theme.mono
        font.pixelSize: root.theme.body
        selectByMouse: true
        background: Rectangle {
            radius: root.theme.radius
            color: root.theme.app
            border.width: parent.activeFocus ? root.theme.focusBorderWidth : 1
            border.color: parent.activeFocus ? root.theme.focusBorder : root.theme.controlBorder
        }
    }
    component Card: Rectangle {
        id: card
        property string icon: ""
        property string label: ""
        property string detail: ""
        property string note: ""
        property bool available: true
        property bool selected: false
        signal chosen()
        Layout.fillWidth: true
        implicitHeight: cardRow.implicitHeight + root.theme.space(18)
        radius: root.theme.radius
        color: selected ? root.theme.line : cardMouse.containsMouse && available ? root.theme.hoverFill : "transparent"
        border.width: 1
        border.color: selected ? root.theme.accent : root.theme.line
        opacity: available ? 1 : 0.55
        RowLayout {
            id: cardRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(12); rightMargin: root.theme.space(12) }
            spacing: root.theme.space(12)
            Icon { theme: root.theme; name: card.icon; size: root.theme.heading + 4; color: card.available ? root.theme.accentText : root.theme.dim }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(2)
                Text { text: card.label; color: root.theme.bright; font.family: root.theme.mono; font.pixelSize: root.theme.body; font.weight: Font.Medium; textFormat: Text.PlainText }
                Text { Layout.fillWidth: true; text: card.detail; color: root.theme.dim; font.family: root.theme.mono; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                Text { Layout.fillWidth: true; visible: card.note !== ""; text: card.note; color: root.theme.muted; font.family: root.theme.mono; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText }
            }
            Icon { theme: root.theme; visible: card.available; name: "chevronRight"; size: root.theme.body; color: root.theme.dim }
        }
        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: card.available
            cursorShape: Qt.PointingHandCursor
            onClicked: card.chosen()
        }
    }
    component Bar: Rectangle {
        property real fraction: 0
        Layout.fillWidth: true
        implicitHeight: root.theme.space(4)
        radius: height / 2
        color: root.theme.line
        Rectangle { width: parent.width * Math.max(0, Math.min(1, parent.fraction)); height: parent.height; radius: parent.radius; color: root.theme.accent }
    }

    // ---- Choose where ----
    ColumnLayout {
        objectName: "syncChoose"
        Layout.fillWidth: true
        visible: root.page === "choose"
        spacing: root.theme.space(8)
        Line { text: "Keep this library the same on all your computers." }
        Hint { text: "Omabib keeps a folder called Omabib wherever you choose: references, notes, clips and PDFs. The library file itself never leaves this computer, and chats stay here too." }
        Rectangle {
            Layout.fillWidth: true
            visible: !!root.app.syncProviders && !root.rcloneReady
            implicitHeight: rcloneRow.implicitHeight + root.theme.space(18)
            radius: root.theme.radius
            color: root.theme.app
            border.width: 1
            border.color: root.theme.line
            RowLayout {
                id: rcloneRow
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(12); rightMargin: root.theme.space(10) }
                spacing: root.theme.space(10)
                Icon { theme: root.theme; name: "download"; size: root.theme.title; color: root.theme.accentText }
                Text {
                    Layout.fillWidth: true
                    text: "Google Drive, Dropbox and OneDrive go through rclone, a free, open-source sync tool. Install it once; this page continues by itself."
                    color: root.theme.text; font.family: root.theme.mono; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText
                }
                TextButton { objectName: "syncInstallRclone"; theme: root.theme; variant: "primary"; icon: "download"; text: "Install rclone"; fontSize: root.theme.small; onClicked: root.app.installRclone() }
            }
        }
        Repeater {
            model: root.providers
            Card {
                required property var modelData
                objectName: "syncProvider:" + modelData.id
                icon: root.providerIcon(modelData.id)
                label: modelData.label
                detail: modelData.folder || ""
                note: modelData.blocked || ""
                available: !!modelData.available
                selected: root.choosing === modelData.id
                onChosen: {
                    root.app.syncError = ""
                    if (modelData.id === "folder" || modelData.id === "rclone") root.choosing = modelData.id
                    else root.app.connectSync(modelData.id, "")
                }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.choosing === "folder"
            spacing: root.theme.space(6)
            Hint { text: "A folder another app keeps in sync: Syncthing, Nextcloud, or Dropbox's own app. Omabib creates Omabib inside it." }
            RowLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(6)
                Field { id: folderField; objectName: "syncFolder"; placeholderText: "/home/you/Sync"; text: root.app.syncFolderGuess() }
                TextButton { theme: root.theme; variant: "primary"; text: "Use this folder"; enabled: folderField.text.trim() !== ""; onClicked: root.app.connectSync("folder", folderField.text.trim()) }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.choosing === "rclone"
            spacing: root.theme.space(6)
            Hint { text: "Set up any storage rclone reaches (S3, R2, B2, WebDAV, Nextcloud…) in Omabib's own rclone config, then give its name here." }
            RowLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(6)
                TextButton { theme: root.theme; icon: "terminal"; text: "Open rclone setup"; onClicked: root.app.openRcloneConfig() }
                Field { id: remoteField; objectName: "syncRemote"; placeholderText: (root.info.rclone && root.info.rclone.remotes && root.info.rclone.remotes[0]) || "remote name" }
                TextButton { theme: root.theme; variant: "primary"; text: "Use it"; enabled: remoteField.text.trim() !== ""; onClicked: root.app.connectSync("rclone", remoteField.text.trim()) }
            }
        }
    }

    // ---- Signing in ----
    ColumnLayout {
        objectName: "syncConnecting"
        Layout.fillWidth: true
        visible: root.page === "connecting"
        spacing: root.theme.space(10)
        Icon { Layout.alignment: Qt.AlignHCenter; Layout.topMargin: root.theme.space(12); theme: root.theme; name: root.providerIcon(root.connecting ? root.connecting.provider : ""); size: root.theme.display * 1.6; color: root.theme.accentText }
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: !root.connecting ? "" : root.connecting.state === "browser" ? "Waiting for you in the browser" : root.connecting.state === "finishing" ? "Finishing…" : "Opening " + root.connecting.label + "…"
            color: root.theme.bright; font.family: root.theme.mono; font.pixelSize: root.theme.title; textFormat: Text.PlainText
        }
        Hint {
            horizontalAlignment: Text.AlignHCenter
            text: !root.connecting ? "" : root.connecting.provider === "drive"
                ? "Allow Omabib in the Google page that opened. It can only see the files it creates in your Drive."
                : "Sign in and click Allow in the " + root.connecting.label + " page that opened. The page says rclone: that's the tool Omabib uses to reach " + root.connecting.label + "."
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: root.theme.space(8)
            TextButton { theme: root.theme; icon: "external"; text: "Open the page again"; visible: !!(root.connecting && root.connecting.url); onClicked: root.app.openExternal(root.connecting.url) }
            TextButton { objectName: "syncCancelConnect"; theme: root.theme; variant: "ghost"; text: "Cancel"; onClicked: root.app.cancelSyncConnect() }
        }
    }

    // ---- New library, or join the one found ----
    ColumnLayout {
        objectName: "syncFound"
        Layout.fillWidth: true
        visible: root.page === "found"
        spacing: root.theme.space(8)
        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: root.providerIcon(root.s.provider ? root.s.provider.provider || root.s.provider.kind : ""); size: root.theme.heading + 4; color: root.theme.accentText }
            Line { text: "Connected to " + (root.s.where || root.placeLabel); color: root.theme.bright }
        }
        Hint { visible: !root.found; text: "Looking for an Omabib library there…" }
        ColumnLayout {
            Layout.fillWidth: true
            visible: !!root.found && root.found.exists === true
            spacing: root.theme.space(6)
            Line {
                text: !root.found || !root.found.exists ? "" : "Found an Omabib library: " + root.count(root.found.counts ? root.found.counts.references : 0, "reference") + ", "
                    + root.count(root.found.counts ? root.found.counts.notes : 0, "note") + ", " + root.count(root.found.counts ? root.found.counts.pdfs : 0, "PDF") + "."
            }
            Hint {
                visible: !!(root.found && root.found.last_device)
                text: root.found && root.found.last_device ? "Last synced from " + root.found.last_device + ", " + Format.relativeTime(root.found.last_updated) + "." : ""
            }
            Hint {
                visible: !!(root.found && root.found.local && root.found.local.references > 0)
                text: root.found && root.found.local ? "This computer has " + root.count(root.found.local.references, "reference") + " and " + root.count(root.found.local.notes, "note") + ". Merge keeps everything from both; Replace uses only the synced library. Either way Omabib backs up this computer's library first." : ""
            }
            RowLayout {
                spacing: root.theme.space(8)
                Layout.topMargin: root.theme.space(4)
                readonly property bool empty: !(root.found && root.found.local && root.found.local.references > 0)
                TextButton { objectName: "syncJoin"; theme: root.theme; variant: "primary"; visible: parent.empty; text: "Use it"; busy: root.app.syncWorking; onClicked: root.app.startSync("join") }
                TextButton { objectName: "syncMerge"; theme: root.theme; variant: "primary"; visible: !parent.empty; text: "Merge"; busy: root.app.syncWorking; onClicked: root.app.startSync("merge") }
                TextButton { objectName: "syncReplace"; theme: root.theme; visible: !parent.empty; text: "Replace this computer's library"; enabled: !root.app.syncWorking; onClicked: root.app.startSync("replace") }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            visible: !!root.found && root.found.exists === false
            spacing: root.theme.space(6)
            Line { text: "There's no Omabib library there yet." }
            Hint {
                text: root.found && root.found.local ? "Start with this one: " + root.count(root.found.local.references, "reference") + ", " + root.count(root.found.local.notes, "note") + " and " + root.count(root.found.local.pdfs, "PDF") + " go up now; after that only changes do." : ""
            }
            TextButton { objectName: "syncStart"; Layout.topMargin: root.theme.space(4); theme: root.theme; variant: "primary"; icon: "cloudSync"; text: "Start syncing"; busy: root.app.syncWorking; onClicked: root.app.startSync("new") }
        }
        TextButton { theme: root.theme; variant: "ghost"; text: "Choose another place"; enabled: !root.app.syncWorking; onClicked: root.app.stopSync() }
    }

    // ---- Syncing ----
    ColumnLayout {
        objectName: "syncStatusPage"
        Layout.fillWidth: true
        visible: root.page === "status"
        spacing: root.theme.space(8)
        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: root.providerIcon(root.s.provider ? root.s.provider.provider || root.s.provider.kind : ""); size: root.theme.heading + 4; color: root.theme.accentText }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(2)
                Line { text: root.s.where || ""; color: root.theme.bright }
                Text {
                    objectName: "syncStateLine"
                    Layout.fillWidth: true
                    text: root.app.syncChipText()
                    color: ["offline", "auth", "full", "error"].indexOf(root.s.state) >= 0 ? root.theme.urgent : root.theme.muted
                    font.family: root.theme.mono; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText
                }
            }
            TextButton { objectName: "syncNow"; theme: root.theme; icon: "sync"; text: root.s.state === "auth" ? "Reconnect" : "Sync now"; busy: root.app.syncWorking || root.s.state === "syncing"; onClicked: root.s.state === "auth" ? root.app.reconnectSync() : root.app.syncNow() }
        }
        Bar { visible: !!root.s.progress; fraction: root.s.progress ? (root.s.progress.done + 1) / Math.max(1, root.s.progress.total) : 0 }

        SectionLabel { theme: root.theme; text: "Computers"; Layout.topMargin: root.theme.space(6) }
        Repeater {
            model: root.s.devices || []
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: root.theme.space(8)
                Icon { theme: root.theme; name: "laptop"; size: root.theme.title; color: modelData.me ? root.theme.accentText : root.theme.muted }
                Text { text: modelData.name + (modelData.me ? " (this computer)" : ""); color: root.theme.text; font.family: root.theme.mono; font.pixelSize: root.theme.body; textFormat: Text.PlainText }
                Item { Layout.fillWidth: true }
                Text { text: modelData.updated ? "synced " + Format.relativeTime(modelData.updated) : ""; color: root.theme.dim; font.family: root.theme.mono; font.pixelSize: root.theme.small; textFormat: Text.PlainText }
            }
        }
        Hint { visible: !(root.s.devices && root.s.devices.length); text: "Computers appear after the first sync." }

        SectionLabel { theme: root.theme; text: "PDFs"; Layout.topMargin: root.theme.space(6) }
        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            Line {
                text: root.s.pdfs ? root.count(root.s.pdfs.here, "PDF") + " on this computer" + (root.s.pdfs.cloud_only ? " · " + root.s.pdfs.cloud_only + " download when you open them" : "") : ""
            }
            TextButton { objectName: "syncDownloadAll"; theme: root.theme; icon: "download"; text: "Download all"; fontSize: root.theme.small; visible: !!(root.s.pdfs && root.s.pdfs.cloud_only); busy: root.app.syncWorking; onClicked: root.app.downloadAllPdfs() }
        }

        SectionLabel { theme: root.theme; text: "Needs your attention"; Layout.topMargin: root.theme.space(6); visible: root.app.syncConflicts.length > 0 }
        Repeater {
            model: root.app.syncConflicts
            Rectangle {
                id: conflict
                required property var modelData
                objectName: "syncConflict"
                Layout.fillWidth: true
                implicitHeight: conflictColumn.implicitHeight + root.theme.space(18)
                radius: root.theme.radius
                color: root.theme.app
                border.width: 1
                border.color: root.theme.line
                ColumnLayout {
                    id: conflictColumn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(9); leftMargin: root.theme.space(12) }
                    spacing: root.theme.space(6)
                    Text { Layout.fillWidth: true; text: conflict.modelData.summary; color: root.theme.bright; font.family: root.theme.mono; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                    Text {
                        Layout.fillWidth: true
                        text: conflict.modelData.kind === "note_copy" ? "The other computer's edit is in the note now; yours was kept as a second note."
                            : conflict.modelData.kind === "deleted" ? "Your changes were kept. Restore brings the paper and its notes back."
                            : "Both references are kept. Delete the one you don't need, or keep both."
                        color: root.theme.dim; font.family: root.theme.mono; font.pixelSize: root.theme.small; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    }
                    RowLayout {
                        spacing: root.theme.space(6)
                        TextButton { theme: root.theme; visible: conflict.modelData.kind === "note_copy"; text: "Keep both"; fontSize: root.theme.small; onClicked: root.app.resolveSyncConflict(conflict.modelData.id, "keep_both") }
                        TextButton { theme: root.theme; visible: conflict.modelData.kind === "note_copy"; text: "Keep mine"; fontSize: root.theme.small; onClicked: root.app.resolveSyncConflict(conflict.modelData.id, "keep_this") }
                        TextButton { theme: root.theme; visible: conflict.modelData.kind === "note_copy"; text: "Keep theirs"; fontSize: root.theme.small; onClicked: root.app.resolveSyncConflict(conflict.modelData.id, "keep_other") }
                        TextButton { theme: root.theme; visible: conflict.modelData.kind === "deleted"; variant: "primary"; text: "Restore"; fontSize: root.theme.small; onClicked: root.app.resolveSyncConflict(conflict.modelData.id, "restore") }
                        TextButton { theme: root.theme; visible: conflict.modelData.kind === "duplicate"; text: "Show it"; fontSize: root.theme.small; onClicked: root.app.openReferenceById(conflict.modelData.ref_id) }
                        TextButton { theme: root.theme; variant: "ghost"; text: conflict.modelData.kind === "deleted" ? "Let it go" : conflict.modelData.kind === "duplicate" ? "Keep both" : "Dismiss"; fontSize: root.theme.small; onClicked: root.app.resolveSyncConflict(conflict.modelData.id, "dismiss") }
                    }
                }
            }
        }

        TextButton { objectName: "syncStop"; Layout.topMargin: root.theme.space(6); theme: root.theme; variant: "ghost"; icon: "cloudOff"; text: "Stop syncing this computer"; enabled: !root.app.syncWorking; onClicked: root.app.stopSync() }
        Hint { text: "Stopping keeps this computer's library as it is. Other computers keep syncing." }
    }

    Text {
        objectName: "syncError"
        Layout.fillWidth: true
        visible: root.app.syncError !== "" || (!!root.connecting && root.connecting.state === "error")
        text: root.app.syncError !== "" ? root.app.syncError : root.connecting ? (root.connecting.message || "") : ""
        color: root.theme.urgent
        font.family: root.theme.mono
        font.pixelSize: root.theme.small
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
}
