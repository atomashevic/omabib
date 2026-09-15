import QtQuick
import QtQuick.Layouts
import QtTest
import "../../plugin/components"
import "fixture.js" as Fixture

// Renders the rail, list and detail panes against a stand-in for App.qml, so
// binding and type errors surface offscreen. Screenshots of every tab go to
// /tmp/omabib-qml-shots for a visual check.
Rectangle {
    id: stage
    width: 1320; height: 840
    color: ui.app
    Theme { id: ui }

    Item {
        id: app
        property var projects: Fixture.projects
        property var hits: Fixture.hits
        property var selected: Fixture.ref
        property string detailTab: "overview"
        property string attentionView: ""
        property string browseSort: "added_desc"
        property string projectId: "p-grl"
        property string projectName: "GRL"
        property int referenceCount: 1602
        property bool candidatesLimited: false
        property bool searchPending: false
        property var nextCursor: null
        property bool codexBusy: false
        property bool pdfBusy: false
        property bool syncBusy: false
        property bool metadataBusy: false
        property bool allNotes: false
        property bool includeOtherNotes: false
        property var noteImages: ({})
        property string homeDir: "/home/reader"
        property bool filtersActive: false
        property string queryText: ""
        property string pdfShortcut: "Ctrl+O"
        property var repoStatus: Fixture.repo
        property string overviewRefId: "r2"
        property string overviewBody: Fixture.overview
        property string overviewState: "ready"
        property string overviewFetchedAt: "2026-09-15 04:00:00"
        property bool overviewCached: true
        property string overviewMessage: ""
        property string actionDigits: ""
        property bool overflowOpen: overflowMenu.opened
        property var calls: []

        function note(name) { calls = calls.concat([name]) }
        function looksLikeIdentifier(text) { return /^10\.|arxiv|^https?:/i.test(String(text || "").trim()) }
        function syncChipText() { return "Changes pending sync" }
        function fileUrl(path) { return "file://" + path }
        function queryEdited() { note("queryEdited") }
        function selectHit(i) { note("selectHit:" + i); list.resultsView.currentIndex = i }
        function selectTab(key) { note("selectTab:" + key); detailTab = key }
        function navigate(d) { note("navigate:" + d) }
        function showDetail() { note("showDetail") }
        function collapseDetail() { note("collapseDetail") }
        function openPdf() { note("openPdf") }
        function getPdf() { note("getPdf") }
        function openLink() { note("openLink") }
        function openExternal(url) { note("openExternal:" + url) }
        function openAlphaXiv() { note("openAlphaXiv") }
        function openCodex(desktop) { note(desktop ? "chatgpt" : "codex") }
        function edit(kind) { note("edit:" + kind) }
        function assign() { note("assign") }
        function copy(text) { note("copy:" + text) }
        function copyFormat(format) { note("copyFormat:" + format) }
        function choosePdf() { note("choosePdf") }
        function pullPdf(id) { note("pullPdf:" + id) }
        function removePdfLink(id) { note("removePdfLink:" + id) }
        function lookupMetadata() { note("lookupMetadata") }
        function loadOverview(force) { note("loadOverview:" + force) }
        function loadNoteImage(n) { note("loadNoteImage:" + n.id) }
        function loadMoreNotes() { note("loadMoreNotes") }
        function toggleOtherNotes() { includeOtherNotes = !includeOtherNotes }
        function toggleSearchAllNotes() { allNotes = !allNotes }
        function requestNoteDelete(id) { note("requestNoteDelete:" + id) }
        function toggleBrowseSort() { note("toggleBrowseSort") }
        function setLibraryView(kind) { note("setLibraryView:" + kind) }
        function setAttentionView(view) { attentionView = view }
        function openProjectMenu(anchor) { note("openProjectMenu") }
        function openAttentionMenu(anchor) { note("openAttentionMenu") }
        function openOverflowMenu(anchor) {
            overflowMenu.items = [
                {key: "metadata", label: "Fill metadata…", icon: "refresh"},
                {key: "bibtex", label: "Edit BibTeX…", icon: "pencil"},
                {section: "Copy"},
                {key: "copy_key", label: "Citation key", icon: "copy"},
                {separator: true},
                {key: "delete", label: "Delete…", icon: "trash", danger: true}
            ]
            overflowMenu.openAt(anchor, "right")
        }
        function openCommands() { palette.open() }
        function openRepoSettings() { note("openRepoSettings") }
        function syncHistory() { note("syncHistory") }
        function startQuickAdd(text) { note("startQuickAdd:" + text) }
        function searchMore() { note("searchMore") }
        function dismiss() { note("dismiss") }
        function actionDigit(d) { actionDigits = actionDigits + d }
        function clearActionDigits() { actionDigits = "" }
        function runAction(n) { note("runAction:" + n); palette.close() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            Rail { id: rail; Layout.fillHeight: true; theme: ui; app: app }
            ListPane { id: list; Layout.fillHeight: true; Layout.preferredWidth: 420; theme: ui; app: app }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: ui.line }
            DetailPane { id: detail; Layout.fillWidth: true; Layout.fillHeight: true; theme: ui; app: app }
        }
        StatusBar {
            id: status
            Layout.fillWidth: true
            theme: ui
            hints: [["↑↓", "navigate"], ["↵", "open"], ["^O", "PDF"], ["^U", "link"], ["^1–5", "tabs"], ["^K", "actions"], ["q", "close"]]
        }
    }

    MenuPopup { id: overflowMenu; theme: ui; menuWidth: 250 }
    CommandPalette { id: palette; theme: ui; app: app }

    TestCase {
        name: "Panes"
        when: windowShown

        function shot(name) {
            wait(180)
            var img = grabImage(stage)
            img.save("/tmp/omabib-qml-shots/" + name + ".png")
        }
        function find(item, name) {
            if (!item) return null
            if (item.objectName === name) return item
            var kids = item.children || []
            for (var i = 0; i < kids.length; i++) {
                var hit = find(kids[i], name)
                if (hit) return hit
            }
            if (item.contentItem && item.contentItem !== item) return find(item.contentItem, name)
            return null
        }

        function init() {
            app.calls = []
            app.selected = Fixture.ref
            app.detailTab = "overview"
            app.overviewState = "ready"
            app.attentionView = ""
            list.resultsView.currentIndex = 1
        }

        function test_1_overview() {
            compare(list.resultsView.count, Fixture.hits.length)
            verify(find(list, "searchField"), "search field keeps its objectName")
            verify(find(list, "sortButton"), "sort button keeps its objectName")
            shot("1-overview")
        }
        function test_2_ai_summary() {
            app.detailTab = "ai"
            wait(100)
            var column = find(detail, "overviewMarkdown")
            verify(column, "AI summary column keeps objectName overviewMarkdown")
            verify(column.children.length > 8, "overview renders its blocks")
            shot("2-ai-summary")
            app.overviewState = "loading"
            shot("2b-ai-loading")
            app.overviewState = "unavailable"
            shot("2c-ai-unavailable")
        }
        function test_2d_prose_overview() {
            app.overviewBody = Fixture.overviewProse
            app.detailTab = "ai"
            wait(100)
            var column = find(detail, "overviewMarkdown")
            verify(column.children.length >= 6, "prose overview renders its blocks")
            shot("2d-ai-prose-nested")
            app.overviewBody = Fixture.overview
        }
        function test_3_notes() {
            app.detailTab = "notes"
            shot("3-notes")
        }
        function test_4_files() {
            app.detailTab = "files"
            shot("4-files")
        }
        function test_5_bibtex() {
            app.detailTab = "bibtex"
            shot("5-bibtex")
        }
        function test_6_overflow_menu() {
            var button = find(detail, "overflowButton")
            verify(button, "overflow button")
            mouseClick(button)
            tryCompare(overflowMenu, "opened", true)
            shot("6-overflow")
            overflowMenu.close()
            tryCompare(overflowMenu, "opened", false)
        }
        function test_7_palette_filters_and_digits() {
            palette.open()
            tryCompare(palette, "opened", true)
            shot("7-palette")
            keyClick(Qt.Key_2)
            compare(app.actionDigits, "2")
            keyClick(Qt.Key_Return)
            verify(app.calls.indexOf("runAction:2") >= 0, "Return runs the typed number: " + app.calls)
            tryCompare(palette, "opened", false)
            palette.open()
            tryCompare(palette, "opened", true)
            keyClick(Qt.Key_H); keyClick(Qt.Key_I); keyClick(Qt.Key_S); keyClick(Qt.Key_T)
            compare(palette.matches.length, 1)
            compare(palette.matches[0].n, 19)
            shot("7b-palette-filtered")
            keyClick(Qt.Key_Return)
            verify(app.calls.indexOf("runAction:19") >= 0, "Return runs the filtered action: " + app.calls)
        }
        function test_8_no_abstract_and_empty() {
            var r = JSON.parse(JSON.stringify(Fixture.ref))
            r.abstract = ""
            r.fields = {journal: "Journal of Examples", doi: "10.1000/example"}
            r.notes = []
            app.selected = r
            shot("8-no-abstract")
            app.detailTab = "notes"
            shot("8b-no-notes")
            app.selected = null
            app.hits = []
            wait(50)
            shot("8c-empty")
            app.hits = Fixture.hits
        }
        function test_9_tab_clicks_select() {
            app.detailTab = "overview"
            wait(50)
            var tabs = detail.children[0].children[1]
            verify(tabs.current === "overview")
            // The toolbar and tab strip route to the app's verbs.
            app.selectTab("files")
            compare(app.detailTab, "files")
        }
    }
}
