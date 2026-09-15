import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Search header and results. App.qml keeps the state and the verbs; this
// draws them and routes the search field's keys.
Rectangle {
    id: root

    required property var theme
    required property var app
    readonly property Item queryField: search.input
    readonly property Item resultsView: list
    readonly property Item authorField: author.input
    readonly property Item yearField: year.input
    readonly property Item typeField: type.input
    readonly property Item labelField: label.input
    readonly property Item projectAnchor: projectChip
    property bool filtersOpen: false
    property bool wide: false

    color: theme.app

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: root.theme.space(12)
            Layout.bottomMargin: root.theme.space(10)
            spacing: root.theme.space(10)

            RowLayout {
                Layout.fillWidth: true
                spacing: root.theme.space(4)
                Chip {
                    id: projectChip
                    theme: root.theme
                    icon: "folder"
                    text: root.app.projectName
                    trailingIcon: "chevronDown"
                    bordered: false
                    clickable: true
                    textColor: root.theme.bright
                    tooltip: "Project  ·  Ctrl+P"
                    onClicked: root.app.openProjectMenu(projectChip)
                }
                Text {
                    text: root.app.referenceCount.toLocaleString(Qt.locale(), "f", 0) + " references"
                    color: root.theme.dim
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.body
                    textFormat: Text.PlainText
                }
                Chip {
                    theme: root.theme
                    visible: root.app.attentionView !== ""
                    icon: "alert"
                    iconColor: root.theme.accentText
                    text: root.app.attentionView === "missing_pdf" ? "no PDF" : "no abstract"
                    trailingIcon: "close"
                    clickable: true
                    tooltip: "Show all references"
                    Layout.leftMargin: root.theme.space(4)
                    onClicked: root.app.setAttentionView("")
                }
                Item { Layout.fillWidth: true }
                TextButton {
                    objectName: "sortButton"
                    theme: root.theme
                    variant: "ghost"
                    icon: "sort"
                    fontSize: root.theme.small
                    text: search.text.trim() !== "" ? "Relevance" : root.app.browseSort === "added_desc" ? "Newest" : "A–Z"
                    enabled: search.text.trim() === ""
                    onClicked: root.app.toggleBrowseSort()
                }
                IconButton {
                    theme: root.theme
                    icon: "filter"
                    iconSize: root.theme.title
                    size: root.theme.space(26)
                    active: root.filtersOpen || root.app.filtersActive
                    tooltip: "Filters"
                    onClicked: root.filtersOpen = !root.filtersOpen
                }
            }

            QueryField {
                id: search
                Layout.fillWidth: true
                theme: root.theme
                icon: "search"
                placeholder: "Search title, author, abstract, notes…"
                inputName: "searchField"
                onTextChanged: root.app.queryEdited()
                onShortcutOverride: event => {
                    if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_U || event.key === Qt.Key_O))
                        event.accepted = true
                    else if (event.key === Qt.Key_Q && event.modifiers === Qt.NoModifier && search.text.trim() === "")
                        event.accepted = true
                }
                onKeyPressed: event => {
                    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                    if (event.key === Qt.Key_Q && event.modifiers === Qt.NoModifier && search.text.trim() === "") { root.app.dismiss(); event.accepted = true }
                    else if (ctrl && event.key === Qt.Key_U) { root.app.openLink(); event.accepted = true }
                    else if (ctrl && event.key === Qt.Key_O) { root.app.getPdf(); event.accepted = true }
                    else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) { root.app.navigate(1); event.accepted = true }
                    else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) { root.app.navigate(-1); event.accepted = true }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (root.app.hits.length === 0 && root.app.looksLikeIdentifier(search.text)) root.app.startQuickAdd(search.text.trim())
                        else root.app.openPdf()
                        event.accepted = true
                    }
                    else if (event.key === Qt.Key_Tab) { root.app.showDetail(); event.accepted = true }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.filtersOpen
                spacing: root.theme.space(6)
                QueryField { id: author; theme: root.theme; Layout.fillWidth: true; implicitHeight: root.theme.space(28); fontSize: root.theme.body; placeholder: "Author"; onTextChanged: root.app.queryEdited() }
                QueryField { id: year; theme: root.theme; Layout.preferredWidth: root.theme.space(72); implicitHeight: root.theme.space(28); fontSize: root.theme.body; placeholder: "Year"; clearable: false; onTextChanged: root.app.queryEdited() }
                QueryField { id: type; theme: root.theme; Layout.preferredWidth: root.theme.space(104); implicitHeight: root.theme.space(28); fontSize: root.theme.body; placeholder: "Type"; clearable: false; onTextChanged: root.app.queryEdited() }
                QueryField { id: label; theme: root.theme; Layout.preferredWidth: root.theme.space(90); implicitHeight: root.theme.space(28); fontSize: root.theme.body; placeholder: "Label"; clearable: false; onTextChanged: root.app.queryEdited() }
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
                    font.family: root.theme.mono
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
                font.family: root.theme.mono
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
            currentIndex: -1
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds
            onCountChanged: if (count > 0 && currentIndex < 0) currentIndex = 0
            highlightMoveDuration: 0
            delegate: ResultRow {
                theme: root.theme
                current: ListView.isCurrentItem
                showAge: root.app.browseSort === "added_desc" && root.app.queryText === ""
                onActivated: index => root.app.selectHit(index)
            }
            footer: Item {
                width: list.width
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
                contentItem: Rectangle { implicitWidth: root.theme.space(4); color: root.theme.line }
            }
        }
    }

    EmptyState {
        theme: root.theme
        anchors.centerIn: parent
        anchors.verticalCenterOffset: root.theme.space(40)
        width: Math.min(parent.width - root.theme.space(40), root.theme.space(460))
        visible: root.app.hits.length === 0 && !root.app.searchPending
        readonly property bool identifier: root.app.looksLikeIdentifier(search.text)
        icon: identifier ? "plus" : root.app.attentionView !== "" && search.text === "" ? "check" : root.app.referenceCount === 0 ? "book" : "search"
        title: identifier ? "Not in your library yet"
            : root.app.attentionView !== "" && search.text === "" ? "Nothing needs attention here"
            : root.app.referenceCount === 0 ? "Your library is empty"
            : "No matching references"
        hint: identifier ? "Press Enter to look it up and add it"
            : root.app.referenceCount === 0 ? "Paste a DOI, arXiv ID or URL above, or press + to add one"
            : root.app.attentionView !== "" && search.text === "" ? ""
            : "Try fewer words, another project, or clear the filters"
        detail: identifier ? "Fetches metadata, the abstract and an open-access PDF when available" : ""
    }
}
