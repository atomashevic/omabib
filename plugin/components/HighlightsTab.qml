import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

// The open PDF's highlights in reading order, each with its color, page and
// comment. A click goes to the passage; a right-click opens its menu.
ScrollPane {
    id: root

    required property var reader
    readonly property var marks: reader.orderedHighlights

    sidePadding: theme.space(18)

    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(12)
        Text {
            Layout.fillWidth: true
            text: root.marks.length === 1 ? "1 highlight" : root.marks.length + " highlights"
            color: root.theme.muted
            font.family: root.theme.sans
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
        }
        TextButton {
            theme: root.theme
            icon: "highlighter"
            text: root.reader.tool === "highlight" ? "Stop highlighting" : "Highlight text"
            onClicked: root.reader.tool = root.reader.tool === "highlight" ? "select" : "highlight"
        }
    }

    EmptyState {
        theme: root.theme
        Layout.fillWidth: true
        Layout.topMargin: root.theme.space(48)
        visible: root.marks.length === 0
        icon: "highlighter"
        iconColor: root.theme.muted
        title: "No highlights yet"
        hint: "Pick up the highlighter (m) and drag over text, or right-click a selection and choose Highlight."
    }

    Repeater {
        model: root.marks
        Rectangle {
            id: card
            objectName: "highlightCard"
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: body.implicitHeight + root.theme.space(20)
            color: cardHover.hovered ? root.theme.hoverFill : root.theme.raised
            border.width: 1
            border.color: root.reader.focusMark === modelData.id ? root.reader.highlightInk(modelData.color, true) : root.theme.line
            radius: root.theme.radiusLarge

            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: root.theme.space(10) }
                width: root.theme.space(4)
                radius: width / 2
                color: root.reader.highlightInk(card.modelData.color, true)
            }
            ColumnLayout {
                id: body
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: root.theme.space(24); rightMargin: root.theme.space(12); topMargin: root.theme.space(10) }
                spacing: root.theme.space(6)
                Text {
                    Layout.fillWidth: true
                    text: card.modelData.quote || ""
                    color: root.theme.text
                    font.family: root.theme.readingFamily
                    font.pixelSize: root.theme.body
                    lineHeight: 1.25
                    wrapMode: Text.Wrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: card.modelData.comment || ""
                    color: root.theme.muted
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Text {
                    text: "p. " + card.modelData.page + (card.modelData.created_at ? " · " + Format.relativeTime(card.modelData.created_at) : "")
                    color: root.theme.dim
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                    textFormat: Text.PlainText
                }
            }
            HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.reader.goToHighlight(card.modelData) }
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: eventPoint => root.reader.openMarkMenu(card.modelData, card, eventPoint.position.x, eventPoint.position.y)
            }
        }
    }
}
