import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A keyboard-driven menu anchored to a control (projects, needs-attention
// views, the detail toolbar's overflow) or opened where the pointer is (the
// reader's right-click menu).
Popup {
    id: root

    required property var theme
    // [{key, label, icon?, shortcut?, danger?, selected?, section?}]
    // An entry with `section` draws a small heading; `separator: true` a line;
    // `swatches: [{key, color, selected?}]` a row of color dots to click.
    property var items: []
    property int cursor: 0
    property real menuWidth: theme.space(240)

    signal triggered(string key)

    readonly property var actionable: items.filter(function (i) { return !i.section && !i.separator && !i.swatches })
    function rowHeight(i) {
        return i.separator ? theme.space(9) : i.section ? theme.space(24) : i.swatches ? theme.space(34) : theme.space(30)
    }
    // From the entries, as the rows may not be laid out yet when the menu opens.
    readonly property real menuHeight: items.reduce(function (h, i) { return h + rowHeight(i) }, theme.space(8))
    // items index -> position among actionable entries, or -1.
    readonly property var actionMap: {
        var n = 0
        return items.map(function (i) { return i.section || i.separator || i.swatches ? -1 : n++ })
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
        // The first selected entry: a menu with sections may select one in each.
        for (var i = 0; i < actionable.length && sel < 0; i++) if (actionable[i].selected) sel = i
        cursor = Math.max(0, sel)
        open()
    }

    // At a point in `item`, as a right-click menu opens: below and right of
    // the pointer, or above and left of it where the window ends.
    function openAtPoint(item, px, py) {
        var p = item.mapToItem(parent, px, py)
        var gap = root.theme.space(8)
        x = p.x + menuWidth + gap > parent.width ? Math.max(gap, p.x - menuWidth) : p.x
        y = p.y + menuHeight + gap > parent.height ? Math.max(gap, p.y - menuHeight) : p.y
        cursor = 0
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
        color: root.theme.raised
        border.width: 1
        border.color: root.theme.border
        radius: root.theme.radius + root.theme.space(2)
        Shadow { theme: root.theme; radius: parent.radius; reach: 18 }
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
                objectName: modelData.key ? "menuItem:" + modelData.key : ""
                // The map can trail a change of entries by one evaluation.
                readonly property int actionIndex: index < root.actionMap.length ? root.actionMap[index] : -1
                readonly property bool hot: actionIndex >= 0 && actionIndex === root.cursor
                Layout.fillWidth: true
                implicitHeight: root.rowHeight(modelData)

                Rectangle {
                    visible: !!entry.modelData.separator
                    anchors.centerIn: parent
                    width: parent.width - root.theme.space(16); height: 1
                    color: root.theme.line
                }
                Text {
                    visible: !!entry.modelData.section
                    anchors { left: parent.left; leftMargin: root.theme.space(14); bottom: parent.bottom; bottomMargin: root.theme.space(4) }
                    text: entry.modelData.section || ""
                    color: root.theme.muted
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                    font.weight: Font.DemiBold
                }
                Row {
                    visible: !!entry.modelData.swatches
                    anchors { left: parent.left; leftMargin: root.theme.space(38); verticalCenter: parent.verticalCenter }
                    spacing: root.theme.space(8)
                    Repeater {
                        model: entry.modelData.swatches || []
                        Rectangle {
                            id: swatch
                            required property var modelData
                            objectName: "menuSwatch:" + modelData.key
                            width: root.theme.space(20); height: width
                            radius: width / 2
                            color: modelData.color
                            border.width: modelData.selected || swatchMouse.containsMouse ? 2 : 1
                            border.color: modelData.selected || swatchMouse.containsMouse ? root.theme.bright : root.theme.line
                            MouseArea {
                                id: swatchMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activate(swatch.modelData)
                            }
                        }
                    }
                }
                Rectangle {
                    visible: entry.actionIndex >= 0 && entry.hot
                    anchors { fill: parent; leftMargin: root.theme.space(4); rightMargin: root.theme.space(4) }
                    radius: root.theme.radiusSmall
                    color: root.theme.hoverFill
                }
                RowLayout {
                    visible: entry.actionIndex >= 0
                    anchors { fill: parent; leftMargin: root.theme.space(14); rightMargin: root.theme.space(12) }
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
                        font.family: root.theme.sans
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
