import QtQuick
import Quickshell

// Hosts plugin/App.qml the way the Omarchy shell does: one long-lived
// instance, shown and hidden by later launches.
Item {
    Loader {
        id: app
        source: DesktopHost.appUrl
        onStatusChanged: if (status === Loader.Error) Qt.exit(1)
    }
    Connections {
        target: DesktopHost
        function onOpenRequested(payload, toggle) {
            const ui = app.item
            if (!ui) return
            if (toggle && ui.opened && DesktopHost.windowActive()) {
                ui.dismiss()
                return
            }
            ui.open(payload)
            DesktopHost.raiseWindows()
        }
    }
}
