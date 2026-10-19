import QtQuick
import QtQuick.Layouts

// The library's sidebar: its places (all references, what needs attention,
// projects), the open papers, and sync and settings at the foot. In a paper
// tab it gives way to PaperRail.
Rectangle {
    id: root

    required property var theme
    required property var app

    readonly property var sync: app.syncStatus || ({})
    readonly property bool syncIssue: ["offline", "auth", "full", "error"].indexOf(sync.state) >= 0
    readonly property var tabs: app.paperTabs || []

    implicitWidth: theme.space(232)
    color: theme.side

    Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right } width: 1; color: root.theme.line }

    ColumnLayout {
        anchors { fill: parent; rightMargin: 1 }
        spacing: 0

        // The same height as the toolbar beside it.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: root.theme.space(52)
            Layout.leftMargin: root.theme.space(18)
            spacing: root.theme.space(9)
            OmabibMark {
                objectName: "omabibMark"
                implicitWidth: root.theme.space(18); implicitHeight: implicitWidth
                color: root.theme.bright
            }
            Text {
                text: "Omabib"
                color: root.theme.bright
                font.family: root.theme.sans
                font.pixelSize: root.theme.title
                font.weight: Font.DemiBold
                textFormat: Text.PlainText
            }
        }

        Flickable {
            id: places
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: column.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: column
                width: places.width
                spacing: root.theme.space(2)

                Heading { text: "Library"; first: true }
                SideItem {
                    objectName: "placeAll"
                    icon: "library"
                    label: "All references"
                    trailing: root.app.referenceCount ? root.app.referenceCount.toLocaleString(Qt.locale(), "f", 0) : ""
                    active: root.app.projectId === "" && root.app.attentionView === ""
                    onClicked: root.app.showPlace("")
                }
                SideItem {
                    id: attention
                    objectName: "placeAttention"
                    icon: "alert"
                    iconColor: root.theme.warn
                    label: root.app.attentionView === "missing_pdf" ? "Missing PDF"
                        : root.app.attentionView === "missing_abstract" ? "Missing abstract" : "Needs attention"
                    active: root.app.attentionView !== ""
                    onClicked: root.app.openAttentionMenu(attention)
                }

                Heading { text: "Open"; visible: root.tabs.length > 0 }
                Repeater {
                    model: root.tabs
                    SideItem {
                        required property var modelData
                        required property int index
                        objectName: (modelData.kind === "pdf" ? "pdfTab:" : "paperTab:") + modelData.citekey
                        icon: modelData.kind === "pdf" ? "pdf" : "document"
                        label: modelData.title || modelData.citekey
                        trailing: modelData.kind === "pdf" && modelData.page > 1 ? "p. " + modelData.page : ""
                        trailingMono: true
                        closable: true
                        tooltip: (modelData.title || modelData.citekey) + (index < 9 ? "  ·  Alt+" + (index + 1) : "")
                        onClicked: root.app.activateTab(index)
                        onMiddleClicked: root.app.closeTab(index)
                        onCloseClicked: root.app.closeTab(index)
                    }
                }

                Heading { text: "Projects" }
                Repeater {
                    model: root.app.projects || []
                    SideItem {
                        required property var modelData
                        required property int index
                        objectName: "project:" + modelData.name
                        icon: "folder"
                        label: modelData.name
                        active: root.app.projectId === modelData.id
                        onClicked: root.app.showPlace(modelData.id)
                    }
                }
                SideItem {
                    objectName: "newProject"
                    icon: "plus"
                    label: "New project"
                    muted: true
                    onClicked: root.app.edit("project")
                }
                Item { Layout.preferredHeight: root.theme.space(8) }
            }
        }

        // Sync, then settings.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: root.theme.space(10)
            spacing: root.theme.space(6)

            Item {
                id: syncCard
                objectName: "railSync"
                Layout.fillWidth: true
                implicitHeight: syncRow.implicitHeight + root.theme.space(18)
                Rectangle {
                    anchors.fill: parent
                    radius: root.theme.radius + 2
                    color: syncMouse.containsMouse ? root.theme.hoverFill : root.theme.raised
                    border.color: root.theme.line
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                MouseArea {
                    id: syncMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.app.openSync()
                }
                RowLayout {
                    id: syncRow
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(10); rightMargin: root.theme.space(6) }
                    spacing: root.theme.space(10)
                    Icon {
                        theme: root.theme
                        name: !root.sync.configured ? "cloudSync" : root.sync.state === "offline" ? "cloudOff" : root.syncIssue ? "cloudAlert" : "cloudCheck"
                        size: root.theme.title + 3
                        color: !root.sync.configured ? root.theme.muted : root.syncIssue ? root.theme.urgent : root.theme.success
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(1)
                        Text {
                            Layout.fillWidth: true
                            text: !root.sync.configured ? "Sync" : (root.sync.provider && root.sync.provider.label) || "Sync"
                            color: root.theme.bright
                            font.family: root.theme.sans
                            font.pixelSize: root.theme.small
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.app.syncChipText()
                            color: root.syncIssue ? root.theme.urgent : root.theme.muted
                            font.family: root.theme.sans
                            font.pixelSize: root.theme.caption
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                    }
                    IconButton {
                        theme: root.theme
                        visible: !!root.sync.configured
                        icon: "refresh"
                        size: root.theme.space(26)
                        iconSize: root.theme.body + 1
                        iconColor: root.theme.muted
                        busy: root.app.syncWorking || root.sync.state === "syncing"
                        tooltip: "Sync now"
                        onClicked: root.app.syncButton()
                    }
                }
            }

            SideItem {
                icon: "sliders"
                label: "Settings"
                muted: true
                onClicked: root.app.openSettings()
            }
        }
    }

    component Heading: Text {
        property bool first: false
        Layout.fillWidth: true
        Layout.leftMargin: root.theme.space(18)
        Layout.topMargin: first ? root.theme.space(4) : root.theme.space(14)
        Layout.bottomMargin: root.theme.space(2)
        color: root.theme.dim
        font.family: root.theme.sans
        font.pixelSize: root.theme.caption
        font.weight: Font.DemiBold
        textFormat: Text.PlainText
    }

    component SideItem: Item {
        id: item
        property string icon: ""
        property color iconColor: root.theme.muted
        property string label: ""
        property string trailing: ""
        property bool trailingMono: false
        property string tooltip: ""
        property bool active: false
        property bool muted: false
        property bool closable: false
        signal clicked()
        signal middleClicked()
        signal closeClicked()

        Layout.fillWidth: true
        Layout.leftMargin: root.theme.space(10)
        Layout.rightMargin: root.theme.space(10)
        implicitHeight: root.theme.space(30)

        Rectangle {
            anchors.fill: parent
            radius: root.theme.radius - 1
            color: item.active ? root.theme.selectedFill : hover.hovered ? root.theme.hoverFill : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: mouse => mouse.button === Qt.MiddleButton ? item.middleClicked() : item.clicked()
        }
        RowLayout {
            anchors { fill: parent; leftMargin: root.theme.space(8); rightMargin: root.theme.space(6) }
            spacing: root.theme.space(10)
            Icon {
                theme: root.theme
                name: item.icon
                size: root.theme.body + 3
                color: item.active ? root.theme.accentText : item.iconColor
            }
            Text {
                Layout.fillWidth: true
                text: item.label
                color: item.muted && !hover.hovered ? root.theme.muted : root.theme.text
                font.family: root.theme.sans
                font.pixelSize: root.theme.body
                font.weight: item.active ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Text {
                visible: item.trailing !== "" && !(item.closable && hover.hovered)
                text: item.trailing
                color: root.theme.muted
                font.family: item.trailingMono ? root.theme.mono : root.theme.sans
                font.pixelSize: root.theme.small
                textFormat: Text.PlainText
            }
            IconButton {
                objectName: "closeTab"
                theme: root.theme
                visible: item.closable && hover.hovered
                icon: "close"
                size: root.theme.space(20)
                iconSize: root.theme.body
                iconColor: root.theme.dim
                tooltip: "Close"
                onClicked: item.closeClicked()
            }
        }
        Tip {
            theme: root.theme
            visible: item.tooltip !== "" && hover.hovered
            text: item.tooltip
        }
    }
}
