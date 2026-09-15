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
        readonly property int maxTabs: 10
        property var paperTabs: []
        property int activeTab: -1
        readonly property bool inPaperTab: activeTab >= 0 && activeTab < paperTabs.length
        readonly property var tabIds: paperTabs.map(function (t) { return t.id })
        function activateTab(i) { note("activateTab:" + i); activeTab = i }
        function closeTab(i) {
            note("closeTab:" + i)
            var tabs = paperTabs.slice(); tabs.splice(i, 1)
            if (activeTab >= tabs.length) activeTab = tabs.length - 1
            paperTabs = tabs
        }
        function openInTab(ref, background) {
            note("openInTab:" + (ref ? ref.citekey : "current") + ":" + (background ? "background" : "front"))
            if (!ref || tabIds.indexOf(ref.id) >= 0 || paperTabs.length >= maxTabs) return
            paperTabs = paperTabs.concat([{id: ref.id, citekey: ref.citekey, title: ref.title, detail_tab: "overview"}])
            if (!background) activeTab = paperTabs.length - 1
        }
        function findInLibrary() { note("findInLibrary") }
        property string cliName: settings.ai_cli === "claude" ? "Claude Code" : "Codex"
        property string desktopName: settings.ai_desktop === "claude" ? "Claude Desktop" : "ChatGPT"
        property var settings: ({pdf_viewer: "", ai_cli: "codex", ai_desktop: "chatgpt"})
        property bool settingsBusy: false
        property var settingsInfo: ({
            settings: settings, path: "/home/reader/.config/omabib/settings.json", claude_desktop_mcp: false,
            pdf_viewers: [
                {id: "org.pwmt.zathura-pdf-mupdf.desktop", name: "Zathura", program: "zathura", system_default: true},
                {id: "org.gnome.Evince.desktop", name: "Document Viewer", program: "evince", system_default: false},
                {id: "com.github.xournalpp.xournalpp.desktop", name: "Xournal++", program: "xournalpp-wrapper", system_default: false}
            ],
            clis: [{id: "codex", name: "Codex CLI", available: true}, {id: "claude", name: "Claude Code", available: true}],
            desktops: [{id: "chatgpt", name: "ChatGPT Desktop", available: true}, {id: "claude", name: "Claude Desktop", available: false}]
        })
        function setSetting(key, value) { var next = Object.assign({}, settings); next[key] = value; settings = next; note("setSetting:" + key + "=" + value) }
        function registerClaudeDesktop() { note("registerClaudeDesktop") }
        function openSettings() { settingsSheet.visible = true }

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
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                TabStrip { id: strip; Layout.fillWidth: true; theme: ui; app: app }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    ListPane { id: list; visible: !app.inPaperTab; Layout.fillHeight: true; Layout.preferredWidth: 420; theme: ui; app: app }
                    Rectangle { visible: !app.inPaperTab; Layout.fillHeight: true; implicitWidth: 1; color: ui.line }
                    DetailPane { id: detail; Layout.fillWidth: true; Layout.fillHeight: true; theme: ui; app: app }
                }
            }
        }
        StatusBar {
            id: status
            Layout.fillWidth: true
            theme: ui
            hints: [["↑↓", "navigate"], ["↵", "open"], ["^O", "PDF"], ["^U", "link"], ["^1–5", "tabs"], ["^K", "actions"], ["q", "close"]]
        }
    }

    Rectangle {
        id: settingsSheet
        visible: false
        anchors.centerIn: parent
        width: 640; height: settingsPanel.implicitHeight + 40
        color: ui.card
        border.width: 1; border.color: ui.border
        SettingsPanel { id: settingsPanel; x: 20; y: 20; width: parent.width - 40; theme: ui; app: app }
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
            app.paperTabs = []
            app.activeTab = -1
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
            wait(150)
            var doc = find(detail, "overviewMarkdown")
            verify(doc, "AI summary document keeps objectName overviewMarkdown")
            var plain = doc.getText(0, doc.length)
            verify(plain.indexOf("Authors and Institutions") >= 0, plain.slice(0, 200))
            verify(plain.indexOf("Research Report") < 0, "title dropped")
            verify(plain.indexOf("Dense MAE") >= 0, "table rendered")
            doc.selectAll()
            verify(doc.selectedText.length > 400, "whole overview selectable across blocks")
            doc.deselect()
            shot("2-ai-summary")
            app.overviewState = "loading"
            shot("2b-ai-loading")
            app.overviewState = "unavailable"
            shot("2c-ai-unavailable")
        }
        function test_2e_drag_selects_and_sections_scroll() {
            app.detailTab = "ai"
            wait(150)
            var doc = find(detail, "overviewMarkdown")
            var pane = doc.parent.parent.parent  // column → contentItem → Flickable
            compare(pane.contentY, 0)
            mousePress(doc, 10, 60)
            mouseMove(doc, 200, 160)
            mouseRelease(doc, 200, 160)
            verify(doc.selectedText.length > 20, "drag selects text: " + doc.selectedText)
            compare(pane.contentY, 0, "drag does not scroll the pane")
            var tab = pane.parent.parent
            tab.jumpTo(tab.sections.length - 1)
            tryVerify(function () { return pane.contentY > 100 }, 1000, "last section chip scrolls down")
            shot("2e-ai-jumped")
            tab.jumpTo(0)
            doc.deselect()
        }
        function test_2d_prose_overview() {
            app.overviewBody = Fixture.overviewProse
            app.detailTab = "ai"
            wait(150)
            var doc = find(detail, "overviewMarkdown")
            var plain = doc.getText(0, doc.length)
            verify(plain.indexOf("Stable routers") >= 0 && plain.indexOf("*") < 0, plain)
            shot("2d-ai-prose-nested")
            app.overviewBody = Fixture.overview
        }
        function test_1b_abstract_selectable() {
            var abstract = find(detail, "abstractText")
            verify(abstract, "abstract text")
            abstract.selectAll()
            verify(abstract.selectedText.indexOf("Transformers for time series") === 0, abstract.selectedText)
            abstract.deselect()
        }
        function test_2f_settings_panel() {
            app.openSettings()
            wait(100)
            var zathura = find(settingsPanel, "pdfViewer:org.pwmt.zathura-pdf-mupdf.desktop")
            verify(zathura, "installed viewers listed")
            mouseClick(zathura)
            compare(app.settings.pdf_viewer, "org.pwmt.zathura-pdf-mupdf.desktop")
            var claude = find(settingsPanel, "aiCli:claude")
            mouseClick(claude)
            compare(app.settings.ai_cli, "claude")
            compare(app.cliName, "Claude Code")
            var desktop = find(settingsPanel, "aiDesktop:claude")
            mouseClick(desktop)
            compare(app.settings.ai_desktop, "chatgpt", "an app that isn't installed can't be chosen")
            app.settingsInfo = Object.assign({}, app.settingsInfo, {desktops: [{id: "chatgpt", name: "ChatGPT Desktop", available: true}, {id: "claude", name: "Claude Desktop", available: true}]})
            wait(50)
            mouseClick(find(settingsPanel, "aiDesktop:claude"))
            compare(app.settings.ai_desktop, "claude")
            shot("2f-settings")
            settingsSheet.visible = false
            app.settings = ({pdf_viewer: "", ai_cli: "codex", ai_desktop: "chatgpt"})
        }
        function test_9b_tabs_open_switch_close() {
            var rows = list.resultsView
            var row = rows.itemAtIndex(0)
            mouseDoubleClickSequence(row)
            compare(app.paperTabs.length, 1)
            compare(app.activeTab, 0, "double-click opens and shows the tab")
            app.activeTab = -1
            mouseClick(rows.itemAtIndex(3), 20, 20, Qt.MiddleButton)
            compare(app.paperTabs.length, 2)
            compare(app.activeTab, -1, "middle-click opens in the background")
            wait(50)
            verify(rows.itemAtIndex(0).inTab && rows.itemAtIndex(3).inTab && !rows.itemAtIndex(1).inTab, "rows open in a tab are marked")
            var second = find(strip, "paperTab:" + Fixture.hits[3].citekey)
            verify(second, "tab rendered")
            mouseClick(second, 40, second.height / 2)
            compare(app.activeTab, 1)
            app.selected = Fixture.ref
            shot("9b-paper-tab")
            mouseClick(find(strip, "libraryTab"), 30, 10)
            compare(app.activeTab, -1)
            mouseClick(find(strip, "paperTab:" + Fixture.hits[0].citekey), 40, 10, Qt.MiddleButton)
            compare(app.paperTabs.length, 1, "middle-click closes a tab")
            var close = find(find(strip, "paperTab:" + Fixture.hits[3].citekey), "closeTab")
            mouseClick(close)
            compare(app.paperTabs.length, 0, "close button closes a tab")
        }
        function test_9c_tabs_stack_when_full() {
            var tabs = []
            for (var i = 0; i < 10; i++) tabs.push({id: "t" + i, citekey: "paper_" + i + "_2026", title: "A fairly long paper title number " + i + " about stacking tabs", detail_tab: i === 4 ? "ai" : "overview"})
            app.paperTabs = tabs
            app.activeTab = 4
            wait(250)
            var deck = find(strip, "paperTabs")
            verify(strip.stacked, "ten tabs overlap at this width")
            var first = find(strip, "paperTab:paper_0_2026"), last = find(strip, "paperTab:paper_9_2026"), active = find(strip, "paperTab:paper_4_2026")
            verify(last.x + last.width <= deck.width + 1, "the last tab stays inside the strip")
            verify(active.z > first.z && active.z > last.z, "the active tab is on top")
            shot("9c-tabs-stacked")
            app.openInTab({id: "t10", citekey: "one_too_many", title: "Eleventh"}, false)
            compare(app.paperTabs.length, 10, "no eleventh tab")
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
