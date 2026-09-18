import QtQuick
import QtQuick.Layouts

// Library views at the top, adding and syncing at the bottom.
Rectangle {
    id: root

    required property var theme
    required property var app

    readonly property var sync: app.syncStatus || ({})
    readonly property bool syncIssue: ["offline", "auth", "full", "error"].indexOf(sync.state) >= 0
    readonly property bool syncPending: !sync.configured || (sync.pending || 0) > 0 || (sync.conflicts || 0) > 0

    implicitWidth: theme.space(48)
    color: theme.app

    Rectangle {
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
        width: 1
        color: root.theme.line
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: root.theme.space(10)
        anchors.bottomMargin: root.theme.space(10)
        spacing: root.theme.space(4)

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: root.theme.space(36)
            implicitWidth: root.theme.space(22)
            OmabibMark {
                objectName: "omabibMark"
                anchors.centerIn: parent
                width: root.theme.space(22); height: width
                color: root.theme.bright
            }
        }
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: root.theme.space(2)
            Layout.bottomMargin: root.theme.space(4)
            implicitWidth: root.theme.space(24); implicitHeight: 1
            color: root.theme.line
        }

        RailButton {
            icon: "library"; tooltip: "All references, A–Z"
            active: root.app.attentionView === "" && root.app.browseSort === "citekey"
            onClicked: root.app.setLibraryView("all")
        }
        RailButton {
            icon: "recent"; tooltip: "Recently added"
            active: root.app.attentionView === "" && root.app.browseSort === "added_desc"
            onClicked: root.app.setLibraryView("recent")
        }
        RailButton {
            id: projectsButton
            icon: "folder"; tooltip: "Projects"; shortcut: "Ctrl+P"
            active: root.app.projectId !== ""
            onClicked: root.app.openProjectMenu(projectsButton)
        }
        RailButton {
            id: attentionButton
            icon: "alert"; tooltip: "Needs attention"
            active: root.app.attentionView !== ""
            onClicked: root.app.openAttentionMenu(attentionButton)
        }

        Item { Layout.fillHeight: true }

        RailButton {
            icon: "plus"; tooltip: "Add a reference"; shortcut: "DOI, arXiv, URL, BibTeX"
            onClicked: root.app.edit("quick")
        }
        RailButton {
            objectName: "railSync"
            icon: root.sync.state === "offline" ? "cloudOff" : root.syncIssue ? "syncAlert" : "sync"
            tooltip: root.app.syncChipText()
            busy: root.app.syncWorking || root.sync.state === "syncing"
            dot: root.syncIssue || root.syncPending
            dotColor: root.syncIssue ? root.theme.urgent : root.theme.accentText
            iconColor: root.syncIssue ? root.theme.urgent : root.theme.muted
            onClicked: root.app.syncButton()
        }
        RailButton {
            objectName: "railSyncSettings"
            icon: "cloudSync"; tooltip: "Sync settings"
            onClicked: root.app.openSync()
        }
        RailButton {
            icon: "command"; tooltip: "Actions"; shortcut: "Ctrl+K"
            onClicked: root.app.openCommands()
        }
        RailButton {
            icon: "cog"; tooltip: "Settings"
            onClicked: root.app.openSettings()
        }
    }

    component RailButton: IconButton {
        theme: root.theme
        Layout.alignment: Qt.AlignHCenter
        size: root.theme.space(36)
        iconSize: root.theme.space(18)
        iconColor: root.theme.muted
    }
}
