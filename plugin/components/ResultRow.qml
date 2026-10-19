import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

// One search result: a title of up to two lines, then authors and year with
// compact state badges (open in a tab, notes, AI overview, PDF, no abstract)
// and, while browsing the newest, how long ago it was added.
Item {
    id: root

    required property var theme
    required property var modelData
    required property int index
    property bool current: false
    property bool showAge: true
    property bool inTab: false

    signal activated(int index)
    // Middle-click opens the paper in a background tab; double-click opens and shows it.
    signal openInTab(int index, bool background)

    readonly property var hit: modelData || ({})

    implicitHeight: column.implicitHeight + theme.space(20)
    width: ListView.view ? ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin : implicitWidth

    Rectangle {
        anchors.fill: parent
        radius: root.theme.radius + 1
        color: root.current ? root.theme.selectedFill : mouse.containsMouse ? root.theme.hoverFill : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    ColumnLayout {
        id: column
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: root.theme.space(12); rightMargin: root.theme.space(12); topMargin: root.theme.space(10) }
        spacing: root.theme.space(4)

        Text {
            Layout.fillWidth: true
            text: root.hit.title || root.hit.citekey || ""
            color: root.theme.bright
            font.family: root.theme.sans
            font.pixelSize: root.theme.body + 0.5
            font.weight: Font.DemiBold
            lineHeight: 1.1
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            Text {
                Layout.fillWidth: true
                text: [Format.shortAuthors(root.hit.authors), root.hit.year].filter(function (s) { return !!s }).join(" · ")
                color: root.theme.muted
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Badge { visible: root.inTab; icon: "tab"; tint: root.theme.accentText }
            Badge { visible: (root.hit.note_count || 0) > 0; icon: "note"; text: String(root.hit.note_count || 0) }
            Badge { visible: !!root.hit.has_overview; icon: "sparkles" }
            Badge { visible: root.hit.has_abstract === false; icon: "alert"; text: "no abstract"; tint: root.theme.warn }
            Rectangle {
                visible: !!root.hit.has_pdf
                implicitWidth: pdfText.implicitWidth + root.theme.space(10)
                implicitHeight: pdfText.implicitHeight + root.theme.space(1)
                radius: root.theme.space(4)
                color: "transparent"
                border.color: root.theme.line
                Text {
                    id: pdfText
                    anchors.centerIn: parent
                    text: "PDF"
                    color: root.theme.muted
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.caption - 0.5
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.3
                    textFormat: Text.PlainText
                }
            }
            Text {
                visible: root.showAge && !!root.hit.created_at
                text: Format.relativeTime(root.hit.created_at)
                color: root.theme.dim
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                textFormat: Text.PlainText
            }
        }

        Repeater {
            model: (root.hit.note_matches || []).slice(0, 1)
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: root.theme.space(6)
                Icon { theme: root.theme; name: "note"; size: root.theme.small; color: root.theme.dim }
                Text {
                    Layout.fillWidth: true
                    text: (modelData.project_name || "Global") + " · " + (modelData.snippet || "")
                    color: root.theme.dim
                    font.family: root.theme.readingFamily
                    font.pixelSize: root.theme.small
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) root.openInTab(root.index, true)
            else root.activated(root.index)
        }
        onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) root.openInTab(root.index, false) }
    }

    component Badge: RowLayout {
        id: badge
        property string icon: ""
        property string text: ""
        property color tint: root.theme.muted
        spacing: root.theme.space(3)
        Icon { theme: root.theme; name: badge.icon; size: root.theme.small; color: badge.tint }
        Text { visible: badge.text !== ""; text: badge.text; color: badge.tint; font.family: root.theme.sans; font.pixelSize: root.theme.small; textFormat: Text.PlainText }
    }
}
