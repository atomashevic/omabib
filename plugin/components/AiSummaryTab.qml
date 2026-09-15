import QtQuick
import QtQuick.Layouts
import "Format.js" as Format
import "OverviewText.js" as OverviewText

// The alphaXiv AI overview, laid out block by block for reading, with a
// strip that jumps between its sections.
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

    function bright(html) {
        var c = root.theme.bright.toString()
        return String(html).replace(/<b>/g, "<b><font color=\"" + c + "\">").replace(/<\/b>/g, "</font></b>")
    }

    function updateCurrentSection() {
        var best = 0
        for (var i = 0; i < sections.length; i++) {
            var item = blockRepeater.itemAt(sections[i].block)
            if (item && item.mapToItem(scroll.column, 0, 0).y <= scroll.contentY + root.theme.space(40)) best = i
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
                onClicked: {
                    var item = blockRepeater.itemAt(modelData.block)
                    if (item) scroll.scrollToItem(item)
                    root.currentSection = index
                }
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
            topPadding: root.theme.space(10)
            column.objectName: "overviewMarkdown"
            column.spacing: root.theme.space(12)
            onContentYChanged: root.updateCurrentSection()

            Repeater {
                id: blockRepeater
                model: root.blocks
                Loader {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.topMargin: modelData.type === "h2" ? root.theme.space(12) : modelData.type === "h3" ? root.theme.space(4) : 0
                    property var block: modelData
                    sourceComponent: modelData.type === "h2" || modelData.type === "h3" ? heading
                        : modelData.type === "ol" || modelData.type === "ul" ? list
                        : modelData.type === "quote" ? quote
                        : modelData.type === "code" ? code
                        : modelData.type === "table" ? table
                        : modelData.type === "hr" ? rule
                        : paragraph
                }
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

    Component {
        id: heading
        RowLayout {
            readonly property var b: parent ? parent.block : ({})
            width: parent ? parent.width : 0
            spacing: root.theme.space(10)
            Text {
                visible: !!b.number
                text: b.number || ""
                color: root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: b.type === "h2" ? root.theme.body : root.theme.small
                Layout.alignment: Qt.AlignBaseline
                textFormat: Text.PlainText
            }
            Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignBaseline
                text: root.bright(b.html || "")
                textFormat: Text.StyledText
                color: root.theme.bright
                font.family: root.theme.readingFamily
                font.pixelSize: b.type === "h2" ? root.theme.heading : root.theme.title
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: paragraph
        Text {
            readonly property var b: parent ? parent.block : ({})
            width: parent ? parent.width : 0
            text: root.bright(b.html || "")
            textFormat: Text.StyledText
            color: root.theme.text
            linkColor: root.theme.accentText
            font.family: root.theme.readingFamily
            font.pixelSize: root.theme.title
            lineHeight: 1.6
            wrapMode: Text.Wrap
            onLinkActivated: link => root.app.openExternal(link)
        }
    }

    Component {
        id: list
        ColumnLayout {
            readonly property var b: parent ? parent.block : ({})
            width: parent ? parent.width : 0
            spacing: root.theme.space(10)
            Repeater {
                model: b.items || []
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: root.theme.space(6)
                    Text {
                        Layout.preferredWidth: root.theme.space(22)
                        Layout.alignment: Qt.AlignTop
                        text: modelData.marker
                        color: root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.body
                        lineHeight: 1.6 * root.theme.title / root.theme.body
                        textFormat: Text.PlainText
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(2)
                        Text {
                            Layout.fillWidth: true
                            text: root.bright(modelData.html)
                            textFormat: Text.StyledText
                            color: root.theme.text
                            linkColor: root.theme.accentText
                            font.family: root.theme.readingFamily
                            font.pixelSize: root.theme.title
                            lineHeight: 1.6
                            wrapMode: Text.Wrap
                            onLinkActivated: link => root.app.openExternal(link)
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: !!modelData.detail
                            text: modelData.detail || ""
                            textFormat: Text.StyledText
                            color: root.theme.muted
                            linkColor: root.theme.accentText
                            font.family: root.theme.readingFamily
                            font.pixelSize: root.theme.title
                            lineHeight: 1.6
                            wrapMode: Text.Wrap
                            onLinkActivated: link => root.app.openExternal(link)
                        }
                        Repeater {
                            model: modelData.sub || []
                            RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.topMargin: root.theme.space(4)
                                spacing: root.theme.space(6)
                                Text {
                                    Layout.preferredWidth: root.theme.space(16)
                                    Layout.alignment: Qt.AlignTop
                                    text: "◦"
                                    color: root.theme.dim
                                    font.family: root.theme.mono
                                    font.pixelSize: root.theme.body
                                    lineHeight: 1.6 * root.theme.title / root.theme.body
                                    textFormat: Text.PlainText
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.bright(modelData)
                                    textFormat: Text.StyledText
                                    color: root.theme.text
                                    linkColor: root.theme.accentText
                                    font.family: root.theme.readingFamily
                                    font.pixelSize: root.theme.title
                                    lineHeight: 1.6
                                    wrapMode: Text.Wrap
                                    onLinkActivated: link => root.app.openExternal(link)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: quote
        RowLayout {
            readonly property var b: parent ? parent.block : ({})
            width: parent ? parent.width : 0
            spacing: root.theme.space(12)
            Rectangle { Layout.fillHeight: true; implicitWidth: 2; color: root.theme.line }
            Text {
                Layout.fillWidth: true
                text: b.html || ""
                textFormat: Text.StyledText
                color: root.theme.muted
                font.family: root.theme.readingFamily
                font.pixelSize: root.theme.title
                font.italic: true
                lineHeight: 1.55
                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: code
        Rectangle {
            readonly property var b: parent ? parent.block : ({})
            width: parent ? parent.width : 0
            implicitHeight: codeText.implicitHeight + root.theme.space(24)
            color: root.theme.app
            border.width: 1
            border.color: root.theme.line
            radius: root.theme.radius
            Text {
                id: codeText
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(12) }
                text: b.text || ""
                textFormat: Text.PlainText
                color: root.theme.text
                font.family: root.theme.mono
                font.pixelSize: root.theme.body
                wrapMode: Text.WrapAnywhere
            }
        }
    }

    Component {
        id: table
        GridLayout {
            readonly property var b: parent ? parent.block : ({})
            width: parent ? parent.width : 0
            columns: Math.max(1, (b.header || []).length)
            rowSpacing: 0
            columnSpacing: 0
            Repeater {
                model: (b.header || []).map(function (h) { return {html: h, head: true} })
                    .concat([].concat.apply([], (b.rows || []).map(function (r) { return r.map(function (c) { return {html: c, head: false} }) })))
                Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    implicitHeight: cell.implicitHeight + root.theme.space(12)
                    color: modelData.head ? root.theme.app : "transparent"
                    border.width: 1
                    border.color: root.theme.line
                    Text {
                        id: cell
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(8); rightMargin: root.theme.space(8) }
                        text: root.bright(modelData.html)
                        textFormat: Text.StyledText
                        color: modelData.head ? root.theme.bright : root.theme.text
                        font.family: modelData.head ? root.theme.mono : root.theme.readingFamily
                        font.pixelSize: root.theme.body
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }

    Component {
        id: rule
        Rectangle { width: parent ? parent.width : 0; implicitHeight: 1; color: root.theme.line }
    }
}
