import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The results: the order and filters over them, then the list. App.qml keeps
// the state and the verbs; the toolbar holds the search field.
Rectangle {
    id: root

    required property var theme
    required property var app
    readonly property Item resultsView: list
    readonly property Item authorField: author.input
    readonly property Item yearField: year.input
    readonly property Item typeField: type.input
    readonly property Item labelField: label.input
    property bool filtersOpen: false
    property bool wide: false

    readonly property bool searching: app.queryText !== ""

    color: theme.app

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: root.theme.space(40)
            Layout.leftMargin: root.theme.space(18)
            Layout.rightMargin: root.theme.space(12)
            spacing: root.theme.space(8)
            Text {
                Layout.fillWidth: true
                text: root.searching ? "Best matches" : root.app.browseSort === "added_desc" ? "Newest first" : "By citation key"
                color: root.theme.muted
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Chip {
                theme: root.theme
                visible: root.app.attentionView !== ""
                icon: "alert"
                iconColor: root.theme.warn
                text: root.app.attentionView === "missing_pdf" ? "no PDF" : "no abstract"
                trailingIcon: "close"
                clickable: true
                tooltip: "Show all references"
                onClicked: root.app.setAttentionView("")
            }
            // Newest | A–Z; a search orders by relevance instead.
            Rectangle {
                objectName: "sortButton"
                visible: !root.searching
                implicitWidth: sortRow.implicitWidth + root.theme.space(4)
                implicitHeight: root.theme.space(26)
                radius: root.theme.radius - 1
                color: root.theme.side
                border.color: root.theme.line
                RowLayout {
                    id: sortRow
                    anchors.centerIn: parent
                    spacing: 0
                    Repeater {
                        model: [["added_desc", "Newest"], ["citekey", "A–Z"]]
                        Item {
                            id: segment
                            required property var modelData
                            readonly property bool on: root.app.browseSort === modelData[0]
                            implicitWidth: segmentText.implicitWidth + root.theme.space(18)
                            implicitHeight: root.theme.space(22)
                            Rectangle {
                                anchors.fill: parent
                                radius: root.theme.radiusSmall - 1
                                color: segment.on ? root.theme.raised : "transparent"
                                border.width: segment.on ? 1 : 0
                                border.color: root.theme.line
                            }
                            Text {
                                id: segmentText
                                anchors.centerIn: parent
                                text: segment.modelData[1]
                                color: segment.on ? root.theme.bright : root.theme.muted
                                font.family: root.theme.sans
                                font.pixelSize: root.theme.small
                                font.weight: segment.on ? Font.DemiBold : Font.Medium
                                textFormat: Text.PlainText
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (!segment.on) root.app.toggleBrowseSort()
                            }
                        }
                    }
                }
            }
            IconButton {
                theme: root.theme
                icon: "filter"
                iconSize: root.theme.title
                size: root.theme.space(26)
                iconColor: root.theme.muted
                active: root.filtersOpen || root.app.filtersActive
                tooltip: "Filters"
                onClicked: root.filtersOpen = !root.filtersOpen
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: root.theme.space(12)
            Layout.rightMargin: root.theme.space(12)
            Layout.bottomMargin: root.theme.space(8)
            visible: root.filtersOpen || root.app.candidatesLimited
            spacing: root.theme.space(8)

            RowLayout {
                Layout.fillWidth: true
                visible: root.filtersOpen
                spacing: root.theme.space(6)
                QueryField { id: author; theme: root.theme; Layout.fillWidth: true; implicitHeight: root.theme.space(28); placeholder: "Author"; onTextChanged: root.app.queryEdited() }
                QueryField { id: year; theme: root.theme; Layout.preferredWidth: root.theme.space(72); implicitHeight: root.theme.space(28); placeholder: "Year"; clearable: false; onTextChanged: root.app.queryEdited() }
                QueryField { id: type; theme: root.theme; Layout.preferredWidth: root.theme.space(104); implicitHeight: root.theme.space(28); placeholder: "Type"; clearable: false; onTextChanged: root.app.queryEdited() }
                QueryField { id: label; theme: root.theme; Layout.preferredWidth: root.theme.space(90); implicitHeight: root.theme.space(28); placeholder: "Label"; clearable: false; onTextChanged: root.app.queryEdited() }
            }
            RowLayout {
                visible: root.filtersOpen
                spacing: root.theme.space(6)
                Icon {
                    theme: root.theme
                    name: root.app.allNotes ? "checkboxMarked" : "checkboxBlank"
                    size: root.theme.title
                    color: root.app.allNotes ? root.theme.accentText : root.theme.muted
                }
                Text {
                    text: "Also search other projects’ notes"
                    color: root.theme.muted
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                    textFormat: Text.PlainText
                }
                TapHandler { onTapped: root.app.toggleSearchAllNotes() }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
            Text {
                Layout.fillWidth: true
                visible: root.app.candidatesLimited
                text: "Showing the strongest matches. Add a word to narrow the search."
                color: root.theme.dim
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
        }

        ListView {
            id: list
            objectName: "results"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.app.hits
            spacing: root.theme.space(2)
            leftMargin: root.theme.space(8)
            rightMargin: root.theme.space(8)
            bottomMargin: root.theme.space(8)
            currentIndex: -1
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds
            onCountChanged: if (count > 0 && currentIndex < 0) currentIndex = 0
            highlightMoveDuration: 0
            delegate: ResultRow {
                theme: root.theme
                current: ListView.isCurrentItem
                showAge: root.app.browseSort === "added_desc" && root.app.queryText === ""
                inTab: root.app.tabIds.indexOf(modelData.id) >= 0
                onActivated: index => root.app.selectHit(index)
                onOpenInTab: (index, background) => root.app.openInTab(root.app.hits[index], background)
            }
            footer: Item {
                width: list.width - list.leftMargin - list.rightMargin
                height: more.visible ? more.implicitHeight + root.theme.space(20) : 0
                TextButton {
                    id: more
                    theme: root.theme
                    anchors.centerIn: parent
                    visible: root.app.nextCursor !== null && root.app.nextCursor !== undefined
                    variant: "ghost"
                    icon: "chevronDown"
                    text: "More results"
                    onClicked: root.app.searchMore()
                }
            }
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                contentItem: Rectangle { implicitWidth: root.theme.space(4); radius: width / 2; color: root.theme.line }
            }
            WheelScroll { theme: root.theme }
        }
    }

    // A new, empty library: the ways to fill it.
    Flickable {
        id: welcomeScroll
        objectName: "welcome"
        visible: root.app.libraryEmpty
        anchors { fill: parent; topMargin: root.theme.space(40) }
        contentHeight: welcome.implicitHeight + root.theme.space(48)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Welcome {
            id: welcome
            theme: root.theme
            app: root.app
            width: Math.min(welcomeScroll.width - root.theme.space(48), root.theme.space(620))
            x: (welcomeScroll.width - width) / 2
            y: Math.max(root.theme.space(16), (welcomeScroll.height - implicitHeight) / 2 - root.theme.space(20))
        }
        WheelScroll { theme: root.theme }
    }

    EmptyState {
        theme: root.theme
        anchors.centerIn: parent
        anchors.verticalCenterOffset: root.theme.space(20)
        width: Math.min(parent.width - root.theme.space(40), root.theme.space(460))
        visible: root.app.hits.length === 0 && !root.app.searchPending && !root.app.libraryEmpty
        readonly property string typed: root.app.query ? root.app.query.text : ""
        readonly property bool identifier: root.app.looksLikeIdentifier(typed)
        icon: identifier ? "plus" : root.app.attentionView !== "" && typed === "" ? "check" : root.app.referenceCount === 0 ? "book" : "search"
        title: identifier ? "Not in your library yet"
            : root.app.attentionView !== "" && typed === "" ? "Nothing needs attention here"
            : root.app.referenceCount === 0 ? "Your library is empty"
            : "No matching references"
        hint: identifier ? "Press Enter to look it up and add it"
            : root.app.referenceCount === 0 ? "Paste a DOI, arXiv ID or URL in the search field, press Add, or drop a PDF here"
            : root.app.attentionView !== "" && typed === "" ? ""
            : "Try fewer words, another project, or clear the filters"
        detail: identifier ? "Fetches metadata, the abstract and an open-access PDF when available" : ""
    }
}
