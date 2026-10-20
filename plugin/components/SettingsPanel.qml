import QtQuick
import QtQuick.Layouts

// Preferences: the theme and reading face, PDF page colors in reader tabs and
// which apps the chat buttons start. App.qml owns reading and writing them
// through omabib-settings.
ColumnLayout {
    id: root

    required property var theme
    required property var app

    readonly property var info: app.settingsInfo || ({})
    readonly property var settings: app.settings || ({})

    spacing: theme.space(8)

    component Hint: Text {
        Layout.fillWidth: true
        color: root.theme.dim
        font.family: root.theme.sans
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
        color: checked ? root.theme.selectedFill : mouse.containsMouse && available ? root.theme.hoverFill : "transparent"
        opacity: available ? 1 : 0.5
        RowLayout {
            anchors { fill: parent; leftMargin: root.theme.space(10); rightMargin: root.theme.space(10) }
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: choice.checked ? "radioOn" : "radioOff"; size: root.theme.title + 1; color: choice.checked ? root.theme.accentText : root.theme.muted }
            Text { text: choice.label; color: choice.checked ? root.theme.bright : root.theme.text; font.family: root.theme.sans; font.pixelSize: root.theme.body; textFormat: Text.PlainText }
            Text { Layout.fillWidth: true; text: choice.detail; color: root.theme.dim; font.family: root.theme.sans; font.pixelSize: root.theme.small; elide: Text.ElideRight; textFormat: Text.PlainText }
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

    // A face to choose, shown in itself: "Aa" over its name.
    component FaceChoice: Rectangle {
        id: face
        property string key: ""
        property string label: ""
        property string family: ""
        readonly property bool checked: (root.settings.reading_font || "sans") === key
        Layout.fillWidth: true
        implicitHeight: root.theme.space(76)
        radius: root.theme.radiusLarge
        color: checked ? root.theme.selectedFill : faceMouse.containsMouse ? root.theme.hoverFill : root.theme.raised
        border.width: checked ? 2 : 1
        border.color: checked ? root.theme.accent : root.theme.line
        ColumnLayout {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(16) }
            spacing: root.theme.space(2)
            Text { text: "Aa"; color: root.theme.bright; font.family: face.family; font.pixelSize: root.theme.heading + 2; font.weight: Font.DemiBold }
            Text { text: face.label; color: root.theme.muted; font.family: root.theme.sans; font.pixelSize: root.theme.small; textFormat: Text.PlainText }
        }
        MouseArea {
            id: faceMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !face.checked
            cursorShape: Qt.PointingHandCursor
            onClicked: root.app.setSetting("reading_font", face.key)
        }
    }

    // The serif sample, read only while Settings is open.
    FontLoader { source: "fonts/SourceSerif4-Semibold.ttf" }

    Text {
        Layout.fillWidth: true
        visible: !root.app.settingsInfo
        text: "Looking for installed apps…"
        color: root.theme.dim
        font.family: root.theme.sans
        font.pixelSize: root.theme.body
    }

    Hint {
        visible: !!root.app.settingsError
        text: root.app.settingsError || ""
        color: root.theme.urgent
    }

    SectionLabel { theme: root.theme; text: "Theme" }
    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(6)
        Repeater {
            model: [["system", "System", "monitor"], ["light", "Light", "sun"], ["dark", "Dark", "moon"]]
                .concat(root.theme.omarchyAvailable ? [["omarchy", "Omarchy", "palette"]] : [])
            Rectangle {
                id: mode
                required property var modelData
                readonly property bool checked: (root.settings.theme || "system") === modelData[0]
                objectName: "theme:" + modelData[0]
                Layout.fillWidth: true
                implicitHeight: root.theme.space(34)
                radius: root.theme.radius
                color: checked ? root.theme.selectedFill : modeMouse.containsMouse ? root.theme.hoverFill : root.theme.raised
                border.width: 1
                border.color: checked ? root.theme.accent : root.theme.line
                RowLayout {
                    anchors.centerIn: parent
                    spacing: root.theme.space(7)
                    Icon { theme: root.theme; name: mode.modelData[2]; size: root.theme.title; color: mode.checked ? root.theme.accentText : root.theme.muted }
                    Text { text: mode.modelData[1]; color: mode.checked ? root.theme.bright : root.theme.text; font.family: root.theme.sans; font.pixelSize: root.theme.body; font.weight: mode.checked ? Font.DemiBold : Font.Medium }
                }
                MouseArea {
                    id: modeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !mode.checked
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.app.setSetting("theme", mode.modelData[0])
                }
            }
        }
    }
    Hint { text: root.theme.omarchyAvailable ? "System follows the desktop's light or dark setting. Omarchy uses the open Omarchy theme, and switches with it." : "System follows the desktop's light or dark setting." }

    SectionLabel { theme: root.theme; text: "Reading font"; Layout.topMargin: root.theme.space(10) }
    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(8)
        FaceChoice { objectName: "readingFont:sans"; key: "sans"; label: "Sans · Mona Sans"; family: root.theme.sans }
        FaceChoice { objectName: "readingFont:serif"; key: "serif"; label: "Serif · Source Serif 4"; family: root.theme.serif }
    }
    Hint { text: "For paper titles, abstracts and notes. The rest of the window stays in sans." }

    SectionLabel { theme: root.theme; text: "PDF pages"; Layout.topMargin: root.theme.space(10) }
    Choice {
        objectName: "pdfColors:original"
        label: "Original colors"
        detail: "as the PDF was made"
        checked: root.settings.pdf_colors !== "theme"
        onChosen: root.app.setSetting("pdf_colors", "original")
    }
    Choice {
        objectName: "pdfColors:theme"
        label: "Theme colors"
        detail: "the theme's background and text"
        checked: root.settings.pdf_colors === "theme"
        onChosen: root.app.setSetting("pdf_colors", "theme")
    }
    Hint { text: root.theme.keys("Reader tabs draw the page in the current theme's colors; colored figures and links keep their hue. Ctrl+R in a reader tab switches. Clips saved to notes keep the PDF's own colors.") }

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

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: codexRow.implicitHeight + root.theme.space(20)
        color: root.theme.app
        border.width: 1
        border.color: root.theme.line
        radius: root.theme.radius
        RowLayout {
            id: codexRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: root.theme.space(12) }
            spacing: root.theme.space(10)
            Text {
                Layout.fillWidth: true
                text: (root.info.codex_mcp || {}).message || "Connect Codex to use your library in any Codex session."
                color: root.theme.text
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            TextButton {
                objectName: "connectCodex"
                theme: root.theme
                text: (root.info.codex_mcp || {}).state === "connected" ? "Connected" : "Connect Codex"
                enabled: ["missing", "error"].indexOf((root.info.codex_mcp || {}).state) !== -1 && !root.app.settingsBusy
                busy: root.app.settingsBusy
                fontSize: root.theme.small
                onClicked: root.app.registerCodex()
            }
        }
    }

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
                font.family: root.theme.sans
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
