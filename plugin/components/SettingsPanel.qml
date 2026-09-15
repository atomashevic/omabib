import QtQuick
import QtQuick.Layouts

// Preferences: which app opens PDFs and which apps the chat buttons start.
// App.qml owns reading and writing them through omabib-settings.
ColumnLayout {
    id: root

    required property var theme
    required property var app

    readonly property var info: app.settingsInfo || ({})
    readonly property var settings: app.settings || ({})
    readonly property var viewers: info.pdf_viewers || []
    readonly property string systemViewer: {
        for (var i = 0; i < viewers.length; i++) if (viewers[i].system_default) return viewers[i].name
        return ""
    }

    spacing: theme.space(8)

    component Hint: Text {
        Layout.fillWidth: true
        color: root.theme.dim
        font.family: root.theme.mono
        font.pixelSize: root.theme.small
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    component Choice: Rectangle {
        id: choice
        property string label: ""
        property string detail: ""
        property bool checked: false
        property bool available: true
        signal chosen()
        Layout.fillWidth: true
        implicitHeight: root.theme.space(32)
        radius: root.theme.radius
        color: checked ? root.theme.line : mouse.containsMouse && available ? root.theme.hoverFill : "transparent"
        opacity: available ? 1 : 0.5
        RowLayout {
            anchors { fill: parent; leftMargin: root.theme.space(10); rightMargin: root.theme.space(10) }
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: choice.checked ? "radioOn" : "radioOff"; size: root.theme.title + 1; color: choice.checked ? root.theme.accentText : root.theme.muted }
            Text { text: choice.label; color: choice.checked ? root.theme.bright : root.theme.text; font.family: root.theme.mono; font.pixelSize: root.theme.body; textFormat: Text.PlainText }
            Text { Layout.fillWidth: true; text: choice.detail; color: root.theme.dim; font.family: root.theme.mono; font.pixelSize: root.theme.small; elide: Text.ElideRight; textFormat: Text.PlainText }
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: choice.available && !choice.checked
            cursorShape: Qt.PointingHandCursor
            onClicked: choice.chosen()
        }
    }

    Text {
        Layout.fillWidth: true
        visible: !root.app.settingsInfo
        text: "Looking for installed apps…"
        color: root.theme.dim
        font.family: root.theme.mono
        font.pixelSize: root.theme.body
    }

    SectionLabel { theme: root.theme; text: "PDF viewer" }
    Choice {
        objectName: "pdfViewer:"
        label: "System default"
        detail: root.systemViewer
        checked: !root.settings.pdf_viewer
        onChosen: root.app.setSetting("pdf_viewer", "")
    }
    Repeater {
        model: root.viewers
        Choice {
            required property var modelData
            objectName: "pdfViewer:" + modelData.id
            label: modelData.name
            detail: modelData.program + (modelData.system_default ? " · system default" : "")
            checked: root.settings.pdf_viewer === modelData.id
            onChosen: root.app.setSetting("pdf_viewer", modelData.id)
        }
    }
    Hint { text: "Opens PDFs from Open PDF, Enter and the Files tab. Page notes (Super+N) and opening Omabib from a PDF (Super+B) work in Zathura." }

    SectionLabel { theme: root.theme; text: "Terminal chat"; Layout.topMargin: root.theme.space(10) }
    Repeater {
        model: root.info.clis || []
        Choice {
            required property var modelData
            objectName: "aiCli:" + modelData.id
            label: modelData.name
            detail: modelData.available ? "" : "not installed"
            available: modelData.available
            checked: root.settings.ai_cli === modelData.id
            onChosen: root.app.setSetting("ai_cli", modelData.id)
        }
    }
    Hint { text: "The terminal button in the detail toolbar. Opens a chat with the reference, its notes and PDF, and Omabib's MCP tools." }

    SectionLabel { theme: root.theme; text: "Desktop chat"; Layout.topMargin: root.theme.space(10) }
    Repeater {
        model: root.info.desktops || []
        Choice {
            required property var modelData
            objectName: "aiDesktop:" + modelData.id
            label: modelData.name
            detail: modelData.available ? "" : "not installed"
            available: modelData.available
            checked: root.settings.ai_desktop === modelData.id
            onChosen: root.app.setSetting("ai_desktop", modelData.id)
        }
    }
    Rectangle {
        Layout.fillWidth: true
        visible: root.settings.ai_desktop === "claude"
        implicitHeight: mcpRow.implicitHeight + root.theme.space(20)
        color: root.theme.app
        border.width: 1
        border.color: root.theme.line
        radius: root.theme.radius
        RowLayout {
            id: mcpRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(12); rightMargin: root.theme.space(10) }
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: root.info.claude_desktop_mcp ? "check" : "alert"; size: root.theme.title; color: root.info.claude_desktop_mcp ? root.theme.accentText : root.theme.urgent }
            Text {
                Layout.fillWidth: true
                text: root.info.claude_desktop_mcp
                    ? "Claude Desktop has Omabib's tools. If you just added them, restart Claude Desktop."
                    : "Claude Desktop can't see your library yet. Adding Omabib keeps your other Claude Desktop settings and saves a backup."
                color: root.theme.text
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            TextButton {
                theme: root.theme
                visible: !root.info.claude_desktop_mcp
                icon: "plus"
                text: "Add Omabib to Claude Desktop"
                fontSize: root.theme.small
                busy: root.app.settingsBusy
                onClicked: root.app.registerClaudeDesktop()
            }
        }
    }
    Hint { text: "The chat button in the detail toolbar. ChatGPT opens an unsent Codex-mode draft; Claude opens a new chat with a prompt to read the reference through Omabib's tools." }

    Hint {
        Layout.topMargin: root.theme.space(8)
        visible: !!root.info.path
        text: "Saved in " + (root.info.path || "")
    }
}
