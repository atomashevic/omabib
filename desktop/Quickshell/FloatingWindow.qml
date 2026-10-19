import QtQuick
import QtQuick.Window

// Quickshell's FloatingWindow as an ordinary top-level window. The host
// raises it when a later launch asks for Omabib.
Window {
    id: window
    property real implicitWidth: 0
    property real implicitHeight: 0
    property size minimumSize: Qt.size(0, 0)
    width: implicitWidth
    height: implicitHeight
    minimumWidth: minimumSize.width
    minimumHeight: minimumSize.height
    // Declared inside an Item, a Window waits for that item's window to be
    // its transient parent before showing; App.qml's root Item has none.
    transientParent: null
    Component.onCompleted: DesktopHost.trackWindow(window)
}
