import QtQuick
import QtQuick.Layouts
import "Format.js" as Format
import "OverviewText.js" as OverviewText

// The alphaXiv AI overview as one selectable document, with a strip that
// jumps between its sections.
ColumnLayout {
    id: root

    required property var theme
    required property var app

    readonly property var ref: app.selected
    readonly property bool loaded: !!ref && app.overviewRefId === ref.id && app.overviewState === "ready"
    readonly property var blocks: loaded ? OverviewText.blocks(app.overviewBody) : []
    readonly property var sections: OverviewText.sections(blocks)
    property int currentSection: 0

    spacing: 0

    // The overview as one selectable rich-text document.
    readonly property string html: loaded ? OverviewText.toHtml(blocks, theme.markdownStyle(theme.app), app.mathCache) : ""
    onBlocksChanged: app.ensureMath(OverviewText.mathKeys(blocks))
    // Character offset of each section heading in the document's plain text.
    property var headingOffsets: []

    function locateHeadings() {
        var plain = doc.getText(0, doc.length)
        var offsets = [], from = 0
        for (var i = 0; i < sections.length; i++) {
            var title = String(blocks[sections[i].block].text || "").replace(/[*_`]/g, "").slice(0, 32)
            var at = title ? plain.indexOf(title, from) : -1
            offsets.push(at)
            if (at >= 0) from = at + title.length
        }
        headingOffsets = offsets
    }
    function sectionY(i) {
        var at = headingOffsets[i]
        return at === undefined || at < 0 ? -1 : doc.y + doc.positionToRectangle(at).y
    }
    function jumpTo(i) {
        var y = sectionY(i)
        if (y >= 0) scroll.scrollToY(y)
        currentSection = i
    }
    function updateCurrentSection() {
        // At the bottom the last sections can't reach the top of the view, so
        // count any heading that is on screen.
        var atEnd = scroll.contentY >= scroll.contentHeight - scroll.height - 2
        var limit = scroll.contentY + (atEnd ? scroll.height - root.theme.space(40) : root.theme.space(40))
        var best = 0
        for (var i = 0; i < sections.length; i++) {
            var y = sectionY(i)
            if (y >= 0 && y <= limit) best = i
        }
        currentSection = best
    }

    // Source line.
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: root.theme.space(24)
        Layout.rightMargin: root.theme.space(18)
        Layout.topMargin: root.theme.space(12)
        Layout.bottomMargin: root.theme.space(8)
        spacing: root.theme.space(8)
        Icon { theme: root.theme; name: "sparkles"; size: root.theme.title; color: root.theme.accentText }
        Text {
            text: "AI-generated overview by alphaXiv"
            color: root.theme.bright
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
        }
        Text {
            visible: root.loaded
            text: "·  " + (root.app.overviewCached ? "cached · " : "") + "fetched " + Format.relativeTime(root.app.overviewFetchedAt)
            color: root.theme.dim
            font.family: root.theme.mono
            font.pixelSize: root.theme.small
            textFormat: Text.PlainText
        }
        Item { Layout.fillWidth: true }
        TextButton {
            theme: root.theme
            visible: root.loaded
            variant: "ghost"
            icon: "copy"
            fontSize: root.theme.small
            text: "Copy"
            onClicked: root.app.copy(root.app.overviewBody)
        }
        TextButton {
            theme: root.theme
            variant: "ghost"
            icon: "external"
            fontSize: root.theme.small
            text: "Open on alphaXiv"
            onClicked: root.app.openAlphaXiv()
        }
    }

    Flow {
        Layout.fillWidth: true
        Layout.leftMargin: root.theme.space(24)
        Layout.rightMargin: root.theme.space(18)
        Layout.bottomMargin: root.theme.space(12)
        visible: root.sections.length > 1
        spacing: root.theme.space(6)
        Repeater {
            model: root.sections
            Chip {
                required property var modelData
                required property int index
                theme: root.theme
                text: (modelData.number ? modelData.number + "  " : "") + modelData.title
                selected: index === root.currentSection
                clickable: true
                onClicked: root.jumpTo(index)
            }
        }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.line }

    Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        ScrollPane {
            id: scroll
            anchors.fill: parent
            theme: root.theme
            visible: root.loaded
            topPadding: root.theme.space(14)
            onContentYChanged: root.updateCurrentSection()

            ReadingText {
                id: doc
                objectName: "overviewMarkdown"
                Layout.fillWidth: true
                theme: root.theme
                text: root.html
                onTextChanged: Qt.callLater(root.locateHeadings)
                onOpenLink: url => root.app.openExternal(url)
            }
        }

        ColumnLayout {
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(24) }
            visible: root.app.overviewState === "loading" || root.app.overviewState === "idle"
            spacing: root.theme.space(12)
            Repeater {
                model: [0.42, 0.96, 0.9, 0.93, 0.61, 0.3, 0.95, 0.88, 0.72]
                Rectangle {
                    required property real modelData
                    required property int index
                    Layout.preferredWidth: Math.min(root.theme.space(680), parent.width) * modelData
                    implicitHeight: index === 0 || index === 5 ? root.theme.space(16) : root.theme.space(11)
                    Layout.topMargin: index === 5 ? root.theme.space(14) : 0
                    color: root.theme.line
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.55; to: 1; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1; to: 0.55; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
            }
        }

        EmptyState {
            theme: root.theme
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -root.theme.space(40)
            visible: root.app.overviewState === "unavailable"
            icon: "sparkles"
            title: "No alphaXiv overview for this paper yet"
            hint: "alphaXiv writes overviews for many recent arXiv papers; check back later."
            TextButton { theme: root.theme; icon: "external"; text: "Open on alphaXiv"; onClicked: root.app.openAlphaXiv() }
        }

        EmptyState {
            theme: root.theme
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -root.theme.space(40)
            visible: root.app.overviewState === "error"
            icon: "alert"
            title: "Couldn't load the overview"
            detail: root.app.overviewMessage
            TextButton { theme: root.theme; icon: "refresh"; text: "Try again"; onClicked: root.app.loadOverview(true) }
        }
    }
}
