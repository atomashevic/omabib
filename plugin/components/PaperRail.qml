import QtQuick
import QtQuick.Layouts

// The sidebar, narrowed while a paper shows: the way back to the library at
// the top, then the open papers in the sidebar's order, numbered for Alt+1–9.
Rectangle {
    id: root

    required property var theme
    required property var app

    readonly property var tabs: app.paperTabs || []

    implicitWidth: theme.space(72)
    color: theme.side

    Rectangle { anchors { top: parent.top; bottom: parent.bottom; right: parent.right } width: 1; color: root.theme.line }

    ColumnLayout {
        anchors { fill: parent; rightMargin: 1 }
        spacing: 0

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: root.theme.space(52)
            OmabibMark {
                anchors.centerIn: parent
                width: root.theme.space(18); height: width
                color: root.theme.bright
            }
        }

        Item {
            id: library
            objectName: "libraryTab"
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: root.theme.space(56)
            implicitHeight: libraryColumn.implicitHeight + root.theme.space(14)
            Rectangle {
                anchors.fill: parent
                radius: root.theme.radius + 2
                color: libraryHover.hovered ? root.theme.hoverFill : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }
            }
            HoverHandler { id: libraryHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.app.activateTab(-1) }
            ColumnLayout {
                id: libraryColumn
                anchors.centerIn: parent
                spacing: root.theme.space(4)
                Icon {
                    Layout.alignment: Qt.AlignHCenter
                    theme: root.theme
                    name: "library"
                    size: root.theme.title + 5
                    color: libraryHover.hovered ? root.theme.bright : root.theme.muted
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Library"
                    color: libraryHover.hovered ? root.theme.bright : root.theme.muted
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.caption
                    font.weight: Font.DemiBold
                    textFormat: Text.PlainText
                }
            }
            Tip {
                theme: root.theme
                visible: libraryHover.hovered
                text: "Back to " + root.app.backLabel + "  ·  Esc"
            }
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: root.theme.space(10)
            Layout.bottomMargin: root.theme.space(14)
            implicitWidth: root.theme.space(28); implicitHeight: 1
            color: root.theme.line
        }

        Flickable {
            id: deck
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: thumbs.implicitHeight + root.theme.space(12)
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: thumbs
                width: deck.width
                spacing: root.theme.space(16)

                Repeater {
                    model: root.tabs
                    Item {
                        id: thumb
                        required property var modelData
                        required property int index
                        readonly property bool active: root.app.activeTab === index
                        readonly property bool pdf: modelData.kind === "pdf"
                        objectName: (pdf ? "pdfTab:" : "paperTab:") + modelData.citekey
                        Layout.alignment: Qt.AlignHCenter
                        implicitWidth: root.theme.space(38)
                        implicitHeight: root.theme.space(50)

                        // The ring around the current paper, and a quieter one on hover.
                        Rectangle {
                            anchors { fill: parent; margins: -root.theme.space(4) }
                            radius: root.theme.space(7)
                            color: thumb.active ? root.theme.selectedFill : "transparent"
                            border.width: 2
                            border.color: thumb.active ? root.theme.accent : thumbHover.hovered ? root.theme.line : "transparent"
                        }
                        // A small page: a title, then lines of text.
                        Rectangle {
                            anchors.fill: parent
                            radius: root.theme.space(3)
                            color: root.theme.pageBackground
                            border.width: thumb.active ? 0 : 1
                            border.color: root.theme.line
                            Repeater {
                                model: [[0.0, 0.0, 3], [0.0, 0.25, 2], [0.0, 0.0, 2], [0.0, 0.18, 2], [0.0, 0.0, 2]]
                                Rectangle {
                                    required property var modelData
                                    required property int index
                                    x: root.theme.space(7)
                                    y: root.theme.space(9) + index * root.theme.space(6) + (index > 1 ? root.theme.space(2) : 0)
                                    width: parent.width - root.theme.space(14) - parent.width * modelData[1]
                                    height: modelData[2]
                                    radius: 1
                                    color: Qt.rgba(root.theme.pageText.r, root.theme.pageText.g, root.theme.pageText.b, index === 0 ? 0.75 : 0.25)
                                }
                            }
                            Icon {
                                visible: !thumb.pdf
                                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: root.theme.space(5) }
                                theme: root.theme
                                name: "document"
                                size: root.theme.body
                                color: root.theme.dim
                            }
                        }
                        // Alt+N, for the first nine.
                        Rectangle {
                            visible: thumb.index < 9
                            anchors { right: parent.right; bottom: parent.bottom; rightMargin: -root.theme.space(7); bottomMargin: -root.theme.space(6) }
                            implicitWidth: Math.max(height, number.implicitWidth + root.theme.space(8))
                            implicitHeight: root.theme.space(16)
                            radius: height / 2
                            color: thumb.active ? root.theme.accentFill : root.theme.raised
                            border.width: thumb.active ? 0 : 1
                            border.color: root.theme.line
                            Text {
                                id: number
                                anchors.centerIn: parent
                                text: String(thumb.index + 1)
                                color: thumb.active ? root.theme.onAccent : root.theme.muted
                                font.family: root.theme.mono
                                font.pixelSize: root.theme.caption - 1
                                font.weight: Font.DemiBold
                                textFormat: Text.PlainText
                            }
                        }
                        HoverHandler { id: thumbHover; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onClicked: mouse => mouse.button === Qt.MiddleButton ? root.app.closeTab(thumb.index) : root.app.activateTab(thumb.index)
                        }
                        IconButton {
                            objectName: "closeTab"
                            visible: thumbHover.hovered
                            anchors { right: parent.right; top: parent.top; rightMargin: -root.theme.space(9); topMargin: -root.theme.space(9) }
                            theme: root.theme
                            icon: "close"
                            size: root.theme.space(18)
                            iconSize: root.theme.caption
                            iconColor: root.theme.muted
                            Rectangle { anchors.fill: parent; z: -1; radius: width / 2; color: root.theme.raised; border.color: root.theme.line }
                            onClicked: root.app.closeTab(thumb.index)
                        }
                        Tip {
                            theme: root.theme
                            visible: thumbHover.hovered
                            text: (thumb.modelData.title || thumb.modelData.citekey) + (thumb.index < 9 ? "  ·  Alt+" + (thumb.index + 1) : "")
                        }
                    }
                }
            }
        }
    }
}
