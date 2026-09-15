import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A keyboard-driven menu anchored to a control: projects, needs-attention
// views, and the detail toolbar's overflow.
Popup {
    id: root

    required property var theme
    // [{key, label, icon?, shortcut?, danger?, selected?, section?}]
    // An entry with `section` draws a small heading; `separator: true` a line.
    property var items: []
    property int cursor: 0
    property real menuWidth: theme.space(240)

    signal triggered(string key)

    readonly property var actionable: items.filter(function (i) { return !i.section && !i.separator })
    // items index -> position among actionable entries, or -1.
    readonly property var actionMap: {
        var n = 0
        return items.map(function (i) { return i.section || i.separator ? -1 : n++ })
    }

    // align: "left" drops below the anchor's left edge, "right" below its
    // right edge, "side" opens beside it (the rail).
    function openAt(anchor, align) {
        var side = align === "side"
        var p = anchor.mapToItem(parent, side ? anchor.width + root.theme.space(6) : 0, side ? 0 : anchor.height + root.theme.space(4))
        var wantX = align === "right" ? p.x + anchor.width - menuWidth : p.x
        x = Math.max(root.theme.space(8), Math.min(wantX, parent.width - menuWidth - root.theme.space(8)))
        y = Math.max(root.theme.space(8), Math.min(p.y, parent.height - implicitHeight - root.theme.space(8)))
        var sel = -1
        for (var i = 0; i < actionable.length; i++) if (actionable[i].selected) sel = i
        cursor = Math.max(0, sel)
        open()
    }

    function activate(entry) {
        close()
        triggered(entry.key)
    }

    modal: true
    dim: false
    focus: true
    padding: 0
    width: menuWidth
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        color: root.theme.card
        border.width: 1
        border.color: root.theme.border
        radius: root.theme.radius
    }

    contentItem: ColumnLayout {
        spacing: 0
        focus: true
        Keys.onUpPressed: root.cursor = Math.max(0, root.cursor - 1)
        Keys.onDownPressed: root.cursor = Math.min(root.actionable.length - 1, root.cursor + 1)
        Keys.onReturnPressed: if (root.actionable.length) root.activate(root.actionable[root.cursor])
        Keys.onEnterPressed: if (root.actionable.length) root.activate(root.actionable[root.cursor])

        Item { implicitHeight: root.theme.space(4) }
        Repeater {
            model: root.items
            Item {
                id: entry
                required property var modelData
                required property int index
                readonly property int actionIndex: root.actionMap[index]
                readonly property bool hot: actionIndex >= 0 && actionIndex === root.cursor
                Layout.fillWidth: true
                implicitHeight: modelData.separator ? root.theme.space(9) : modelData.section ? root.theme.space(24) : root.theme.space(30)

                Rectangle {
                    visible: !!entry.modelData.separator
                    anchors.centerIn: parent
                    width: parent.width; height: 1
                    color: root.theme.line
                }
                Text {
                    visible: !!entry.modelData.section
                    anchors { left: parent.left; leftMargin: root.theme.space(12); bottom: parent.bottom; bottomMargin: root.theme.space(4) }
                    text: String(entry.modelData.section || "").toUpperCase()
                    color: root.theme.dim
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.caption
                    font.letterSpacing: 0.4
                }
                Rectangle {
                    visible: entry.actionIndex >= 0
                    anchors.fill: parent
                    color: entry.hot ? root.theme.line : "transparent"
                    Rectangle { visible: entry.hot; anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.accent }
                }
                RowLayout {
                    visible: entry.actionIndex >= 0
                    anchors { fill: parent; leftMargin: root.theme.space(12); rightMargin: root.theme.space(12) }
                    spacing: root.theme.space(10)
                    Icon {
                        theme: root.theme
                        name: entry.modelData.selected ? "check" : (entry.modelData.icon || "")
                        size: root.theme.title
                        color: entry.modelData.danger ? root.theme.urgent : entry.modelData.selected ? root.theme.accentText : root.theme.muted
                    }
                    Text {
                        Layout.fillWidth: true
                        text: entry.modelData.label || ""
                        color: entry.modelData.danger ? root.theme.urgent : entry.hot ? root.theme.bright : root.theme.text
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.body
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Keycap { theme: root.theme; visible: !!entry.modelData.shortcut; text: entry.modelData.shortcut || "" }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: entry.actionIndex >= 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.cursor = entry.actionIndex
                    onClicked: root.activate(entry.modelData)
                }
            }
        }
        Item { implicitHeight: root.theme.space(4) }
    }
}
