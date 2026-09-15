import QtQuick
import QtQuick.Layouts
import "Format.js" as Format

// One search result: a two-line title in the reading font, then authors and
// year with compact state badges (PDF, AI overview, notes, no abstract).
Item {
    id: root

    required property var theme
    required property var modelData
    required property int index
    property bool current: false
    property bool showAge: true

    signal activated(int index)

    readonly property var hit: modelData || ({})

    implicitHeight: column.implicitHeight + theme.space(18)
    width: ListView.view ? ListView.view.width : implicitWidth

    Rectangle {
        anchors.fill: parent
        color: root.current ? root.theme.line : mouse.containsMouse ? root.theme.hoverFill : "transparent"
        Rectangle {
            visible: root.current
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: root.theme.accent
        }
    }

    ColumnLayout {
        id: column
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: root.theme.space(12); rightMargin: root.theme.space(12); topMargin: root.theme.space(9) }
        spacing: root.theme.space(4)

        Text {
            Layout.fillWidth: true
            text: root.hit.title || root.hit.citekey || ""
            color: root.current ? root.theme.bright : root.theme.text
            font.family: root.theme.readingFamily
            font.pixelSize: root.theme.subtitle
            font.weight: Font.Medium
            lineHeight: 1.08
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(9)
            Text {
                Layout.fillWidth: true
                text: [Format.shortAuthors(root.hit.authors), root.hit.year].filter(function (s) { return !!s }).join(" · ")
                color: root.theme.muted
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Badge { theme: root.theme; visible: !!root.hit.has_pdf; icon: "pdf"; text: "PDF" }
            Badge { theme: root.theme; visible: !!root.hit.has_overview; icon: "sparkles"; text: "AI" }
            Badge { theme: root.theme; visible: (root.hit.note_count || 0) > 0; icon: "note"; text: String(root.hit.note_count || 0) }
            Badge { theme: root.theme; visible: root.hit.has_abstract === false; icon: "alert"; text: "no abstract"; tint: root.theme.accentText }
            Text {
                visible: root.showAge && !!root.hit.created_at
                text: Format.relativeTime(root.hit.created_at)
                color: root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: root.theme.caption
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
        onClicked: root.activated(root.index)
    }

    component Badge: RowLayout {
        id: badge
        required property var theme
        property string icon: ""
        property string text: ""
        property color tint: theme.muted
        spacing: theme.space(3)
        Icon { theme: badge.theme; name: badge.icon; size: badge.theme.small; color: badge.tint }
        Text { text: badge.text; color: badge.tint; font.family: badge.theme.mono; font.pixelSize: badge.theme.caption; textFormat: Text.PlainText }
    }
}
