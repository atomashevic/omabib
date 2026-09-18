import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "components"

// The shell can load this entry before the native backend is installed.
Item {
    id: root
    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool ready: false
    property string pendingPayload: "{}"
    property string setupError: ""
    property string setupAction: "status"
    readonly property string setupScript: decodeURIComponent(String(Qt.resolvedUrl("../scripts/omabib-plugin")).replace(/^file:\/\//, ""))
    readonly property bool busy: setup.running
    readonly property string pluginId: "io.github.atomashevic.omabib"

    function open(payloadJson) {
        pendingPayload = payloadJson || "{}"
        opened = true
        if (ready && app.item) app.item.open(pendingPayload)
        else if (!busy) runSetup("status")
    }
    function close() {
        opened = false
        if (app.item) app.item.close()
    }
    function toggle(payloadJson) { if (opened) close(); else open(payloadJson) }
    function runSetup(action) {
        setupError = ""
        setupAction = action
        setup.command = ["python3", setupScript, action]
        setup.running = true
    }
    Component.onCompleted: runSetup("status")
    Theme { id: setupTheme }
    Process {
        id: setup
        property string response: ""
        property string diagnostic: ""
        stdout: StdioCollector { onStreamFinished: setup.response = text }
        stderr: StdioCollector { onStreamFinished: setup.diagnostic = text }
        onStarted: { response = ""; diagnostic = "" }
        onExited: (code, status) => {
            var result = {}
            try { result = JSON.parse(response) } catch (e) {}
            root.setupError = result.error || (code !== 0 ? (diagnostic || "Setup could not start. Please retry.") : "")
            root.ready = result.ready === true
        }
    }
    Loader {
        id: app
        active: root.ready
        source: "App.qml"
        onLoaded: {
            item.shell = root.shell
            item.manifest = root.manifest
            if (root.opened) item.open(root.pendingPayload)
        }
    }
    Connections {
        target: app.item
        function onOpenedChanged() { root.opened = app.item.opened }
    }
    onShellChanged: if (app.item) app.item.shell = shell
    onManifestChanged: if (app.item) app.item.manifest = manifest
    FloatingWindow {
        id: welcome
        objectName: "omabibSetup"
        visible: root.opened && !root.ready
        title: "Omabib"
        implicitWidth: 520
        implicitHeight: Math.max(320, content.implicitHeight + 64)
        color: setupTheme.app
        onVisibleChanged: if (!visible && root.opened && !root.ready) { root.close(); if(root.shell) root.shell.hide(root.pluginId) }
        Rectangle {
            objectName: "omabibSetupSurface"
            anchors.fill: parent
            color: setupTheme.app
            ColumnLayout {
                id: content
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 32 }
                spacing: 18
                Text { text: "Welcome to Omabib"; font.pixelSize: 26; font.bold: true; color: setupTheme.bright }
                Text {
                    Layout.fillWidth: true
                    text: "Your papers, notes, and agents in one place."
                    color: setupTheme.text; font.pixelSize: 16; wrapMode: Text.Wrap
                }
                Text {
                    Layout.fillWidth: true
                    text: root.busy ? (root.setupAction === "install" ? "Installing Omabib…" : "Opening Omabib…")
                          : "Install the app to get started. Your library and settings carry over when updating."
                    color: setupTheme.muted; font.pixelSize: 14; wrapMode: Text.Wrap
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.setupError !== ""
                    text: root.setupError; color: setupTheme.urgent; wrapMode: Text.Wrap
                    maximumLineCount: 4; elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                RowLayout {
                    TextButton {
                        id: installButton
                        theme: setupTheme
                        variant: "primary"
                        focusable: true
                        text: root.setupError ? "Try again" : "Install Omabib"
                        enabled: !root.busy
                        onClicked: root.runSetup("install")
                    }
                    TextButton { theme: setupTheme; text: "Close"; focusable: true; onClicked: root.close() }
                }
            }
        }
        Shortcut { sequence: "Escape"; onActivated: root.close() }
    }
}
