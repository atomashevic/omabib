import QtQuick
import QtQuick.Layouts
import qs.Ui

// The library tab (search, with the project picker) and the paper tabs.
// Paper tabs shrink to fit; when they no longer fit they overlap like a deck,
// the active tab on top.
Rectangle {
    id: root

    required property var theme
    required property var app
    readonly property Item projectAnchor: projectButton

    readonly property var tabs: app.paperTabs || []
    readonly property int count: tabs.length
    readonly property real preferredWidth: theme.space(210)
    readonly property real minimumWidth: theme.space(128)
    readonly property real tabWidth: count ? Math.max(minimumWidth, Math.min(preferredWidth, deck.width / count)) : preferredWidth
    readonly property real step: count > 1 ? Math.min(tabWidth, Math.max(theme.space(18), (deck.width - tabWidth) / (count - 1))) : tabWidth
    readonly property bool stacked: step < tabWidth - 0.5

    implicitHeight: theme.space(36)
    color: theme.app

    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.line }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Library tab.
        Item {
            id: library
            objectName: "libraryTab"
            readonly property bool active: !root.app.inPaperTab
            Layout.fillHeight: true
            implicitWidth: libraryRow.implicitWidth + root.theme.space(22)
            Rectangle {
                anchors.fill: parent
                color: library.active ? root.theme.selectedFill : libraryMouse.containsMouse ? root.theme.hoverFill : "transparent"
            }
            Rectangle { visible: library.active; anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.accent }
            Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom; topMargin: root.theme.space(8); bottomMargin: root.theme.space(8) } width: 1; color: root.theme.line }
            MouseArea {
                id: libraryMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.app.activateTab(-1)
            }
            RowLayout {
                id: libraryRow
                anchors { left: parent.left; leftMargin: root.theme.space(12); verticalCenter: parent.verticalCenter }
                spacing: root.theme.space(7)
                Icon { theme: root.theme; name: root.app.projectId ? "folder" : "library"; size: root.theme.title; color: library.active ? root.theme.accentText : root.theme.muted }
                Text {
                    text: root.app.projectName
                    color: library.active ? root.theme.bright : root.theme.text
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.body
                    font.weight: Font.Medium
                    textFormat: Text.PlainText
                }
                Text {
                    text: root.app.referenceCount.toLocaleString(Qt.locale(), "f", 0)
                    color: root.theme.dim
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.small
                    textFormat: Text.PlainText
                }
                IconButton {
                    id: projectButton
                    theme: root.theme
                    icon: "chevronDown"
                    size: root.theme.space(22)
                    iconSize: root.theme.body + 1
                    iconColor: root.theme.muted
                    tooltip: "Project"
                    shortcut: "Ctrl+P"
                    onClicked: root.app.openProjectMenu(projectButton)
                }
            }
        }

        // Paper tabs.
        Item {
            id: deck
            objectName: "paperTabs"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: root.theme.space(2)
            Layout.rightMargin: root.theme.space(8)
            clip: true

            Repeater {
                model: root.tabs
                Item {
                    id: tab
                    required property var modelData
                    required property int index
                    readonly property bool active: root.app.activeTab === index
                    readonly property bool hot: tabMouse.containsMouse || close.hot
                    objectName: (modelData.kind === "pdf" ? "pdfTab:" : "paperTab:") + modelData.citekey
                    x: index * root.step
                    width: root.tabWidth
                    height: deck.height
                    // The active tab is on top; the rest fall away from it.
                    z: active ? root.count + 2 : hot ? root.count + 1 : root.count - Math.abs(index - Math.max(0, root.app.activeTab))
                    Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                    Rectangle {
                        anchors.fill: parent
                        color: root.theme.app
                        Rectangle {
                            anchors.fill: parent
                            color: tab.active ? root.theme.selectedFill : tab.hot ? root.theme.hoverFill : "transparent"
                        }
                        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: root.stacked ? 0 : root.theme.space(8); bottomMargin: root.stacked ? 1 : root.theme.space(8) } width: 1; color: root.stacked ? root.theme.controlBorder : "transparent" }
                        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom; topMargin: root.stacked ? 0 : root.theme.space(8); bottomMargin: root.stacked ? 1 : root.theme.space(8) } width: 1; color: root.stacked ? root.theme.controlBorder : root.theme.line }
                        Rectangle { visible: tab.active; anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.accent }
                    }
                    MouseArea {
                        id: tabMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton) root.app.closeTab(tab.index)
                            else root.app.activateTab(tab.index)
                        }
                    }
                    RowLayout {
                        anchors { fill: parent; leftMargin: root.theme.space(10); rightMargin: root.theme.space(4) }
                        spacing: root.theme.space(6)
                        Icon {
                            theme: root.theme
                            name: tab.modelData.kind === "pdf" ? "pdf" : tab.modelData.detail_tab === "ai" ? "sparkles" : "document"
                            size: root.theme.body + 1
                            color: tab.active ? root.theme.accentText : root.theme.dim
                        }
                        Text {
                            Layout.fillWidth: true
                            text: tab.modelData.title || tab.modelData.citekey
                            color: tab.active ? root.theme.bright : tab.hot ? root.theme.text : root.theme.muted
                            font.family: root.theme.readingFamily
                            font.pixelSize: root.theme.body
                            font.weight: tab.active ? Font.Medium : Font.Normal
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                        IconButton {
                            id: close
                            objectName: "closeTab"
                            theme: root.theme
                            opacity: tab.active || tab.hot ? 1 : 0.55
                            icon: "close"
                            size: root.theme.space(22)
                            iconSize: root.theme.body
                            iconColor: root.theme.dim
                            tooltip: "Close tab"
                            shortcut: tab.active ? "Ctrl+W" : ""
                            onClicked: root.app.closeTab(tab.index)
                        }
                    }
                    PanelToolTip {
                        visible: tabMouse.containsMouse && !close.hot
                        text: tab.modelData.citekey + "  ·  " + (tab.modelData.title || "")
                        fontFamily: root.theme.mono
                    }
                }
            }
        }

        Text {
            Layout.rightMargin: root.theme.space(12)
            visible: root.count >= root.app.maxTabs - 2
            text: root.count + " / " + root.app.maxTabs
            color: root.count >= root.app.maxTabs ? root.theme.accentText : root.theme.dim
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
        }
    }
}
