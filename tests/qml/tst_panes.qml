import QtQuick
import QtQuick.Layouts
import QtTest
import "../../plugin/components"
import "fixture.js" as Fixture

// Renders the sidebar or paper rail, the toolbar or reader bar, and the list
// and detail panes against a stand-in for App.qml, so binding and type errors
// surface offscreen. Screenshots of every tab go to
// /tmp/omabib-qml-shots for a visual check.
Rectangle {
    id: stage
    width: 1320; height: 840
    color: ui.app
    Theme { id: ui }
    // The faces and icons App.qml loads.
    Repeater {
        model: ["MonaSans-Regular", "MonaSans-Medium", "MonaSans-SemiBold", "lucide"]
        Item { id: bundled; required property string modelData; FontLoader { source: "../../plugin/components/fonts/" + bundled.modelData + ".ttf" } }
    }

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
        // Sync stand-in.
        property var syncStatus: ({})
        property var syncProviders: null
        property var syncFound: null
        property var syncConflicts: []
        property bool syncWorking: false
        property string syncError: ""
        function syncButton() { note("syncButton") }
        function openSync() { note("openSync") }
        function connectSync(provider, arg) { note("connectSync:" + provider + ":" + arg) }
        function cancelSyncConnect() { note("cancelSyncConnect") }
        function startSync(mode) { note("startSync:" + mode) }
        function stopSync() { note("stopSync") }
        function syncNow() { note("syncNow") }
        function reconnectSync() { note("reconnectSync") }
        function downloadAllPdfs() { note("downloadAllPdfs") }
        function resolveSyncConflict(id, action) { note("resolve:" + id + ":" + action) }
        function openReferenceById(id) { note("openReferenceById:" + id) }
        function installRclone() { note("installRclone") }
        function openRcloneConfig() { note("openRcloneConfig") }
        function syncFolderGuess() { return "/home/reader/Sync" }
        // Welcome and Zotero stand-in.
        property bool libraryEmpty: false
        property var zotero: null
        property bool zoteroLooking: false
        property var zoteroOptions: ({pdfs: "copy", groups: true, notes: true, projects: true})
        property bool zoteroImporting: false
        property var zoteroProgress: null
        property var zoteroResult: null
        property string zoteroError: ""
        function openZotero() { note("openZotero") }
        function chooseZoteroFolder() { note("chooseZoteroFolder") }
        function detectZotero(path) { note("detectZotero:" + path) }
        function openBibPicker() { note("openBibPicker") }
        function openPdfPicker() { note("openPdfPicker") }
        function setZoteroOption(key, value) { var o = Object.assign({}, zoteroOptions); o[key] = value; zoteroOptions = o; note("setZoteroOption:" + key) }
        property bool metadataBusy: false
        property bool allNotes: false
        property bool includeOtherNotes: false
        property var noteImages: ({})
        property int connectionEpoch: 0
        property var lastClip: null
        property var composer: null
        property bool composerSaving: false
        property string composerError: ""
        property var saved: null
        function saveComposer(body, projectId, labels, evidence) { saved = {body: body, projectId: projectId, labels: labels, evidence: evidence}; note("saveComposer") }
        function cancelComposer() { composer = null; note("cancelComposer") }
        property var activePaper: activeTab >= 0 && activeTab < paperTabs.length ? paperTabs[activeTab] : null
        function arxivIdOf(ref) { return ref && ref.fields && /arxiv/i.test(ref.fields.doi || "") ? "2609.01234" : "" }
        function updateTab(index, changes) { var tabs = paperTabs.slice(); tabs[index] = Object.assign({}, tabs[index], changes); paperTabs = tabs }
        function editClip(clip) { lastClip = clip; note("editClip:" + clip.page) }
        // The reader's service calls, answered from fixtures.
        function rpc(method, params, callback, onError) {
            note(method + ":" + (params.page || params.query || params.ref_id || ""))
            rpcLog = rpcLog.concat([{method: method, params: params}])
            var page = function (i) { return {x0: 0, y0: 0, w: 612, h: 792} }
            var answer = null
            if (method === "pdf_open") answer = {doc_id: "d1", path: "/lib/paper.pdf", ref_id: params.ref_id, attachment_id: "a1", page_count: 3, pages: [page(0), page(1), page(2)], title: "", outline: [{title: "Introduction", level: 0, page: 1}, {title: "Results", level: 0, page: 3}, {title: "Table 2", level: 1, page: 3}]}
            else if (method === "pdf_render") answer = {path: String(Qt.resolvedUrl("page.png")).replace(/^file:\/\//, ""), width: 306, height: 396, scale: params.scale, links: params.page === 1 ? [{rect: [72, 300, 300, 330], page: 3, uri: null}] : []}
            else if (method === "pdf_text") answer = {page: params.page, words: [["Sparse", 72, 66, 148, 99, 0, 0], ["attention", 154, 66, 246, 99, 0, 0], ["Table", 72, 129, 110, 145, 1, 0], ["headline", 176, 129, 221, 145, 1, 0]]}
            else if (method === "pdf_search") answer = {query: params.query, hits: [{page: 2, rects: [[176, 129, 221, 145]]}], total: 1, truncated: false}
            else if (method === "pdf_highlights") answer = {highlights: []}
            else if (method === "add_highlight") {
                var id = "h" + (++highlightSeq)
                answer = {id: id, ref_id: params.ref_id, attachment_id: params.attachment_id, page: params.page, rects: params.rects, quote: params.quote, color: params.color || "yellow", comment: "", created_at: "2026-09-15T07:00:00Z"}
                var added = Object.assign({}, highlightStore)
                added[id] = answer
                highlightStore = added
            } else if (method === "update_highlight") {
                answer = Object.assign({}, highlightStore[params.id])
                if (params.color !== undefined) answer.color = params.color
                if (params.comment !== undefined) answer.comment = params.comment
                var edited = Object.assign({}, highlightStore)
                edited[params.id] = answer
                highlightStore = edited
            } else if (method === "delete_highlight") answer = {id: params.id, deleted: true}
            if (!answer) { if (onError) onError("unsupported"); return 1 }
            Qt.callLater(callback, answer)
            return 1
        }
        property var mathCache: ({})
        property var mathRequested: []
        function ensureMath(items) { mathRequested = mathRequested.concat(Array.from(items || [], function (m) { return m.key })) }
        property string homeDir: "/home/reader"
        property bool filtersActive: false
        property string queryText: ""
        property string pdfShortcut: "Ctrl+O"
        property string overviewRefId: "r2"
        property string overviewBody: Fixture.overview
        property string overviewState: "ready"
        property string overviewFetchedAt: "2026-09-15 04:00:00"
        property bool overviewCached: true
        property string overviewMessage: ""
        property string actionDigits: ""
        property bool overflowOpen: overflowMenu.opened
        property var calls: []
        property var rpcLog: []
        property var highlightStore: ({})
        property int highlightSeq: 0
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
            paperTabs = paperTabs.concat([{id: ref.id, citekey: ref.citekey, title: ref.title, view: "info", detail_tab: "overview"}])
            if (!background) activeTab = paperTabs.length - 1
        }
        // A tab's two views, the paper's details and its PDF.
        function setView(view) { var tabs = paperTabs.slice(); tabs[activeTab] = Object.assign({}, tabs[activeTab], {view: view}); paperTabs = tabs }
        function showInfo() { note("showInfo"); setView("info") }
        function showPdf() { note("showPdf"); setView("pdf") }
        function findInLibrary() { note("findInLibrary") }
        readonly property bool inPdfTab: inPaperTab && !!activePaper && activePaper.view === "pdf"
        property bool sidebarOpen: true
        readonly property string placeLabel: projectName
        readonly property string backLabel: placeLabel + (queryText !== "" ? " · \u201c" + queryText + "\u201d" : "")
        readonly property string placeSummary: referenceCount + " references"
        readonly property var query: toolbar.queryField
        readonly property var readerPane: reader
        function showPlace(id) { note("showPlace:" + id) }
        function openCiteMenu(anchor) { note("openCiteMenu") }
        function flash(text) { note("flash:" + text) }
        property string cliName: settings.ai_cli === "claude" ? "Claude Code" : "Codex"
        property string desktopName: settings.ai_desktop === "claude" ? "Claude Desktop" : "ChatGPT"
        property var settings: ({pdf_colors: "original", ai_cli: "codex", ai_desktop: "chatgpt", chat_steps: "hidden", claude_model: "", claude_effort: "", codex_model: "", codex_effort: ""})
        readonly property bool pdfThemed: settings.pdf_colors === "theme"
        function togglePdfColors() { setSetting("pdf_colors", pdfThemed ? "original" : "theme") }
        property bool settingsBusy: false
        property string settingsError: ""
        property var settingsInfo: ({
            settings: settings, path: "/home/reader/.config/omabib/settings.json", claude_desktop_mcp: false,
            codex_mcp: {state: "missing", message: "Connect Codex to use your library in any Codex session."},
            clis: [{id: "codex", name: "Codex CLI", available: true}, {id: "claude", name: "Claude Code", available: true}],
            desktops: [{id: "chatgpt", name: "ChatGPT Desktop", available: true}, {id: "claude", name: "Claude Desktop", available: false}],
            agents: [{id: "claude-code", name: "Claude Code", state: "connected", message: "Claude Code is connected. Start a new session to load the tools."},
                     {id: "codex", name: "Codex", state: "missing", message: "Connect Codex to use your library in any Codex session."},
                     {id: "claude-desktop", name: "Claude Desktop", state: "unavailable", message: "Install Claude Desktop to connect your library."}]
        })
        function setSetting(key, value) { var next = Object.assign({}, settings); next[key] = value; settings = next; note("setSetting:" + key + "=" + value) }
        function connectAgent(id) {
            note("connectAgent:" + id)
            var agents = settingsInfo.agents.map(function (a) { return a.id === id ? Object.assign({}, a, {state: "connected", message: a.name + " is connected."}) : a })
            settingsInfo = Object.assign({}, settingsInfo, {agents: agents})
        }
        property bool agentsConnecting: false
        function openSettings() { settingsSheet.visible = true }

        // Chat stand-in: a store the pane reads, and the calls it makes.
        property var chats: ({})
        property var chatForRef: ({})
        property var chatLists: ({})
        property int chatRevision: 0
        property string chatDraft: ""
        property string chatAgent: "claude"
        property var chatAttachment: null
        property bool chatSending: false
        property string chatError: ""
        property int chatFocus: 0
        property var chatModels: ({})
        readonly property bool chatStepsShown: settings.chat_steps === "shown"
        function loadChatModels(agent) {
            if (chatModels[agent]) return
            chatModels[agent] = {models: [{id: "opus", label: "Opus", efforts: ["low", "high"], default_effort: null}, {id: "sonnet", label: "Sonnet", efforts: ["low", "high"], default_effort: null}], default: {model: "opus", effort: null}}
            chatRevision++
        }
        function setChatModel(agent, model, effort) { note("setChatModel:" + agent + ":" + model + ":" + effort) }
        function toggleChatSteps() { settings = Object.assign({}, settings, {chat_steps: chatStepsShown ? "hidden" : "shown"}) }
        readonly property string activeChatId: (chatRevision, selected && chatForRef[selected.id] ? chatForRef[selected.id] : "")
        signal chatEvent(string chatId, var event)
        signal chatReset(string chatId)
        function loadChatFor(ref) { note("loadChatFor") }
        function refreshChatList(ref) { note("refreshChatList") }
        function openChat(id) { note("openChat:" + id) }
        function newChat() { note("newChat") }
        function sendChat(text) { note("sendChat:" + text) }
        function cancelChat() { note("cancelChat") }
        function approveChat(id, allow) { note("approveChat:" + id + ":" + allow) }
        function deleteActiveChat() { note("deleteActiveChat") }
        function openChatInTerminal() { note("openChatInTerminal") }
        function focusChat() { note("focusChat"); detailTab = "chat"; chatFocus++ }
        function askAboutSelection(page, text) { chatAttachment = {selection: {page: page, text: text}}; focusChat() }
        function askAboutClip(clip) { chatAttachment = {clip: clip}; focusChat() }
        function openChatLink(url) { note("openChatLink:" + url) }
        function saveAnswerAsNote(text) { note("saveAnswerAsNote:" + text) }
        function focusActiveTab() { note("focusActiveTab") }
        function pushChat(chatId, kind, data) {
            var st = chats[chatId]
            var e = {seq: st.events.length + 1, kind: kind, data: data}
            st.events.push(e)
            st.lastSeq = e.seq
            chatEvent(chatId, e)
            chatRevision++
        }

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
        function edit(kind, n) { note("edit:" + kind + (n && n.id ? ":" + n.id : "")) }
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
            Sidebar { id: sidebar; visible: !app.inPaperTab && app.sidebarOpen; Layout.fillHeight: true; theme: ui; app: app }
            PaperRail { id: rail; visible: app.inPaperTab; Layout.fillHeight: true; theme: ui; app: app }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: ui.line }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Toolbar { id: toolbar; visible: !app.inPaperTab; Layout.fillWidth: true; theme: ui; app: app }
                ReaderBar { id: readerBar; visible: app.inPaperTab; Layout.fillWidth: true; theme: ui; app: app }
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
    Rectangle {
        id: syncSheet
        visible: false
        anchors.centerIn: parent
        width: 640; height: Math.min(parent.height - 20, syncPanel.implicitHeight + 40)
        color: ui.card
        border.width: 1; border.color: ui.border
        SyncPanel { id: syncPanel; x: 20; y: 20; width: parent.width - 40; theme: ui; app: app }
    }
    Rectangle {
        id: zoteroSheet
        visible: false
        anchors.centerIn: parent
        width: 640; height: Math.min(parent.height - 20, zoteroPanel.implicitHeight + 40)
        color: ui.card
        border.width: 1; border.color: ui.border
        ZoteroPanel { id: zoteroPanel; x: 20; y: 20; width: parent.width - 40; theme: ui; app: app }
    }
    Rectangle {
        id: editorSheet
        visible: false
        anchors.centerIn: parent
        width: 720; height: 520
        color: ui.card
        border.width: 1; border.color: ui.border
        NoteEditor { id: noteEditor; anchors.fill: parent; anchors.margins: 20; theme: ui; app: app; placeholderText: "Write a note…" }
    }
    Rectangle {
        id: readerSheet
        visible: false
        anchors.fill: parent
        color: ui.app
        ReaderPane { id: reader; anchors.fill: parent; theme: ui; app: app }
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
            verify(find(toolbar, "searchField"), "search field keeps its objectName")
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
            var prose = find(detail, "abstractText")
            verify(prose, "abstract text")
            prose.selectAll()
            verify(prose.selectedText.indexOf("Transformers for time series") === 0, prose.selectedText)
            prose.deselect()
        }
        function test_2f_settings_panel() {
            app.openSettings()
            wait(100)
            verify(!find(settingsPanel, "pdfViewer:"), "PDFs open in reader tabs; there is no viewer setting")
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
            // Each agent outside Omabib, with Connect for one that is installed and not connected.
            verify(!find(settingsPanel, "connect:claude-code").visible, "a connected agent has no Connect")
            verify(!find(settingsPanel, "connect:claude-desktop").visible, "an agent that isn't installed has no Connect")
            var connect = find(settingsPanel, "connect:codex")
            verify(connect.visible && connect.enabled)
            mouseClick(connect)
            verify(app.calls.indexOf("connectAgent:codex") >= 0, app.calls)
            compare(app.settingsInfo.agents[1].state, "connected")
            verify(!connect.visible)
            shot("2f-settings")
            settingsSheet.visible = false
            app.settings = ({ai_cli: "codex", ai_desktop: "chatgpt"})
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
            // In the library the open papers are listed in the sidebar.
            var second = find(sidebar, "paperTab:" + Fixture.hits[3].citekey)
            verify(second, "open paper listed in the sidebar")
            mouseClick(second, 40, second.height / 2)
            compare(app.activeTab, 1)
            app.selected = Fixture.ref
            wait(50)
            verify(!sidebar.visible && rail.visible && readerBar.visible && !toolbar.visible, "a paper swaps the sidebar for the rail")
            compare(find(readerBar, "backToLibrary").visible, true)
            shot("9b-paper-tab")
            // The paper and its PDF share the tab: the bar's switch shows one or the other.
            var toPdf = find(readerBar, "tabView:pdf"), toInfo = find(readerBar, "tabView:info")
            verify(toInfo.current && !toPdf.current, "a tab opened from the list shows the paper's details")
            mouseClick(toInfo)
            verify(app.calls.indexOf("showInfo") < 0, "the current view does nothing")
            mouseClick(toPdf)
            verify(app.calls.indexOf("showPdf") >= 0, app.calls)
            compare(app.paperTabs.length, 2, "the PDF opens in the same tab")
            verify(app.inPdfTab && toPdf.current && !toInfo.current)
            mouseClick(toInfo)
            verify(app.calls.indexOf("showInfo") >= 0, app.calls)
            verify(!app.inPdfTab)
            // Switching rewrites the tab list, and the rail lays out its thumbnails again on the next frame.
            wait(50)
            // The rail's thumbnails switch papers; its library button goes back.
            mouseClick(find(rail, "paperTab:" + Fixture.hits[0].citekey))
            compare(app.activeTab, 0)
            mouseClick(find(rail, "libraryTab"))
            compare(app.activeTab, -1)
            wait(50)
            verify(sidebar.visible && toolbar.visible, "back in the library")
            mouseClick(find(sidebar, "paperTab:" + Fixture.hits[0].citekey), 40, 10, Qt.MiddleButton)
            compare(app.paperTabs.length, 1, "middle-click closes a paper")
            // The close button shows on hover, which a synthetic move doesn't give.
            find(find(sidebar, "paperTab:" + Fixture.hits[3].citekey), "closeTab").clicked()
            compare(app.paperTabs.length, 0, "close button closes a paper")
        }
        function test_9c_rail_scrolls_when_full() {
            var tabs = []
            for (var i = 0; i < 10; i++) tabs.push({id: "t" + i, citekey: "paper_" + i + "_2026", title: "A fairly long paper title number " + i + " about many open papers", detail_tab: i === 4 ? "ai" : "overview"})
            app.paperTabs = tabs
            app.activeTab = 4
            wait(250)
            for (var j = 0; j < 10; j++) verify(find(rail, "paperTab:paper_" + j + "_2026"), "paper " + j + " in the rail")
            shot("9c-rail-full")
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
            keyClick(Qt.Key_S); keyClick(Qt.Key_Y); keyClick(Qt.Key_N); keyClick(Qt.Key_C); keyClick(Qt.Key_Space); keyClick(Qt.Key_N); keyClick(Qt.Key_O)
            compare(palette.matches.length, 1)
            compare(palette.matches[0].n, 19)
            shot("7b-palette-filtered")
            keyClick(Qt.Key_Return)
            verify(app.calls.indexOf("runAction:19") >= 0, "Return runs the filtered action: " + app.calls)
            tryCompare(palette, "opened", false)
            palette.open()
            tryCompare(palette, "opened", true)
            keyClick(Qt.Key_P); keyClick(Qt.Key_D); keyClick(Qt.Key_F); keyClick(Qt.Key_Space); keyClick(Qt.Key_I); keyClick(Qt.Key_S); keyClick(Qt.Key_B)
            compare(palette.matches.length, 1)
            compare(palette.matches[0].n, 30)
            keyClick(Qt.Key_Return)
            verify(app.calls.indexOf("runAction:30") >= 0, "Import PDF runs from the palette: " + app.calls)
        }
        function test_15_welcome_add_pdf_and_zotero() {
            var library = {found: true, path: "/home/reader/Zotero", running: true, projects: 62, projects_own: 61, standalone: 35, other_files: 2, loose_notes: 5,
                libraries: [{name: "My Library", group: false, references: 1962, pdfs: 1470, pdfs_missing: 44, pdf_bytes: 3.9e9, notes: 445, annotations: 4148, citation_keys: 1948},
                            {name: "Reading group", group: true, references: 294, pdfs: 120, pdfs_missing: 0, pdf_bytes: 2e8, notes: 3, annotations: 12, citation_keys: 280}]}
            mouseClick(find(toolbar, "addPdfButton"))
            verify(app.calls.indexOf("openPdfPicker") >= 0, "Add PDF in the toolbar: " + app.calls)

            // A new library welcomes, with the Zotero library it found first.
            var hits = app.hits
            app.hits = []
            app.libraryEmpty = true
            app.zotero = library
            wait(80)
            verify(find(list, "welcome").visible)
            shot("15a-welcome-zotero-found")
            mouseClick(find(list, "welcomeZoteroButton"))
            verify(app.calls.indexOf("openZotero") >= 0, app.calls)
            mouseClick(find(list, "welcomeBibtexButton"))
            verify(app.calls.indexOf("openBibPicker") >= 0, app.calls)
            // The agents card pushes the sync line below the fold.
            var welcome = find(list, "welcome")
            welcome.contentY = Math.max(0, welcome.contentHeight - welcome.height)
            wait(50)
            mouseClick(find(list, "welcomeSyncButton"))
            verify(app.calls.indexOf("openSync") >= 0, app.calls)
            // The agents found were connected as the page showed; it says which.
            verify(find(list, "welcomeAgent:claude-code").visible)
            compare(find(list, "welcomeAgent:claude-desktop").text, "Claude Desktop · not installed")
            compare(find(list, "welcomeAgents").title, "Your agents can use this library")
            compare(find(list, "welcomeAgent:codex").text, "Codex · not connected")
            shot("15g-welcome-agents")
            mouseClick(find(list, "welcomeAgentSettings"))
            verify(settingsSheet.visible, "agent settings open")
            settingsSheet.visible = false
            welcome.contentY = 0
            app.zotero = {found: false}
            wait(50)
            shot("15b-welcome-no-zotero")
            mouseClick(find(list, "welcomeZoteroButton"))
            verify(app.calls.indexOf("chooseZoteroFolder") >= 0, app.calls)

            // What Zotero would bring, and the choices.
            app.zotero = library
            zoteroSheet.visible = true
            wait(80)
            verify(find(zoteroPanel, "zoteroFound").visible)
            compare(zoteroPanel.references, 2256)
            compare(zoteroPanel.countText, "2,256 references")
            shot("15c-zotero-found")
            mouseClick(find(zoteroPanel, "zoteroGroups"))
            compare(app.zoteroOptions.groups, false)
            compare(zoteroPanel.references, 1962)
            mouseClick(find(zoteroPanel, "zoteroLink"))
            compare(app.zoteroOptions.pdfs, "link")
            app.zoteroImporting = true
            app.zoteroProgress = {what: "Copying PDFs", done: 312, total: 1470}
            wait(50)
            verify(find(zoteroPanel, "zoteroImporting").visible)
            verify(!zoteroPanel.canImport)
            shot("15d-zotero-importing")
            app.zoteroImporting = false
            app.zoteroResult = {references: 1950, merged: 12, pdfs: 1426, pdfs_missing: 44, pdfs_copied: true, notes: 3100, projects: 61, project_links: 1400, standalone: 35, other_files: 2, loose_notes: 5}
            wait(50)
            verify(find(zoteroPanel, "zoteroDone").visible)
            shot("15e-zotero-done")
            app.zoteroResult = null
            app.zotero = {found: false}
            wait(50)
            verify(find(zoteroPanel, "zoteroMissing").visible)
            shot("15f-zotero-missing")

            zoteroSheet.visible = false
            app.zotero = null
            app.zoteroOptions = {pdfs: "copy", groups: true, notes: true, projects: true}
            app.libraryEmpty = false
            app.hits = hits
            wait(50)
        }
        function mathFixture() {
            function path(name) { return decodeURIComponent(String(Qt.resolvedUrl("math/" + name)).replace(/^file:\/\//, "")) }
            var cache = {}
            cache["I:E = mc^2"] = {path: path("inline.svg"), width: 59, height: 16}
            cache["D:\\int_0^1 x^2 \\, dx = \\frac{1}{3}"] = {path: path("display.svg"), width: 90, height: 40}
            cache["I:\\oops"] = {error: "unknown command: \\oops"}
            return cache
        }
        function test_3b_markdown_note_card() {
            var r = JSON.parse(JSON.stringify(Fixture.ref))
            r.notes = [{id: "n3", body: "## Result\n\nEnergy $E = mc^2$ holds, but $\\oops$ fails and **bold** stays.\n\n$$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$$\n\n```python\nprint('ok') if a < b else None\n```\n\n- one\n- two", project_id: null, project_name: null, labels: ["math"], evidence: "", provenance: "human", revision: 1, created_at: "2026-09-15T07:00:00Z", updated_at: "2026-09-15T07:00:00Z", image: null}]
            app.mathRequested = []
            app.mathCache = mathFixture()
            app.selected = r
            app.detailTab = "notes"
            wait(100)
            var body = find(detail, "noteBody")
            verify(body, "note body renders")
            verify(body.text.indexOf("inline.svg") >= 0 && body.text.indexOf("display.svg") >= 0, body.text)
            verify(body.text.indexOf("&lt; b") >= 0, "code is escaped")
            var plain = body.getText(0, body.length)
            verify(plain.indexOf("Result") === 0 && plain.indexOf("##") < 0, "Markdown syntax is hidden: " + plain)
            verify(plain.indexOf("$\\oops$") >= 0, "a failed formula shows its TeX: " + plain)
            verify(app.mathRequested.indexOf("I:E = mc^2") >= 0, "cards request their math: " + app.mathRequested)
            shot("3b-markdown-note")
            app.mathCache = ({})
        }
        function test_10_note_editor() {
            editorSheet.visible = true
            app.mathRequested = []
            app.mathCache = mathFixture()
            noteEditor.text = "# Title\n\nFirst paragraph with $E = mc^2$.\n\n- a\n- b"
            var area = find(noteEditor, "noteEditorArea")
            verify(area)
            compare(area.text, "- a\n- b", "the last block opens for editing")
            compare(noteEditor.beforeBlocks.length, 2)
            noteEditor.forceActiveFocus()
            wait(50)
            verify(area.activeFocus)
            area.cursorPosition = area.length
            keyClick(Qt.Key_Return)
            compare(area.text, "- a\n- b\n- ", "Enter continues the list")
            keyClick(Qt.Key_C)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Return)
            compare(area.text, "", "Enter on an empty item starts a new block")
            compare(noteEditor.text, "# Title\n\nFirst paragraph with $E = mc^2$.\n\n- a\n- b\n- c\n\n")
            keyClick(Qt.Key_N); keyClick(Qt.Key_O)
            compare(noteEditor.text, "# Title\n\nFirst paragraph with $E = mc^2$.\n\n- a\n- b\n- c\n\nno")
            keyClick(Qt.Key_Up)
            compare(area.text, "- a\n- b\n- c", "Up on the first line edits the previous block")
            keyClick(Qt.Key_Up); keyClick(Qt.Key_Up); keyClick(Qt.Key_Up)
            compare(area.text, "First paragraph with $E = mc^2$.")
            verify(app.mathRequested.indexOf("I:E = mc^2") >= 0, "rendered blocks request math: " + app.mathRequested)
            keyClick(Qt.Key_Down)
            compare(area.text, "- a\n- b\n- c", "Down on the last line edits the next block")
            shot("10-note-editor")

            // A click on a rendered block edits it.
            var heading = find(noteEditor, "noteEditorBlock")
            verify(heading)
            mouseClick(heading, 20, heading.height / 2)
            tryCompare(area, "text", "# Title")
            // Backspace at the start of a block joins it to the previous one.
            keyClick(Qt.Key_Down)
            compare(area.text, "First paragraph with $E = mc^2$.")
            area.cursorPosition = 0
            keyClick(Qt.Key_Backspace)
            compare(area.text, "# Title\nFirst paragraph with $E = mc^2$.")
            compare(noteEditor.text.indexOf("# Title\nFirst paragraph"), 0)

            // Enter stays inside an open fence and leaves a closed one.
            noteEditor.text = ""
            keyClick(Qt.Key_QuoteLeft); keyClick(Qt.Key_QuoteLeft); keyClick(Qt.Key_QuoteLeft)
            keyClick(Qt.Key_Return); keyClick(Qt.Key_Return)
            compare(area.text, "```\n\n", "Enter in an open fence is a newline")
            keyClick(Qt.Key_X); keyClick(Qt.Key_Return)
            keyClick(Qt.Key_QuoteLeft); keyClick(Qt.Key_QuoteLeft); keyClick(Qt.Key_QuoteLeft)
            keyClick(Qt.Key_Return); keyClick(Qt.Key_Return)
            compare(noteEditor.text, "```\n\nx\n```\n\n")
            compare(area.text, "", "a second Enter after the closing fence starts a block")

            // The toolbar wraps the selection.
            noteEditor.text = "plain"
            area.select(0, 5)
            noteEditor.wrap("**", "**", "bold")
            compare(noteEditor.text, "**plain**")
            noteEditor.text = ""
            compare(area.text, "")
            noteEditor.codeOrMath("$$", "$", "x")
            compare(noteEditor.text, "$$\nx\n$$", "math on an empty line is a block")
            verify(noteEditor.sourceBlock)
            wait(400)
            verify(find(noteEditor, "noteEditorMathPreview").visible, "the active formula previews")
            shot("10b-note-editor-math")
            noteEditor.text = ""
            editorSheet.visible = false
            app.mathCache = ({})
        }
        function test_11_pdf_reader() {
            var r = JSON.parse(JSON.stringify(Fixture.ref))
            r.notes = [
                {id: "clip1", body: "Headline clip", project_id: null, labels: [], provenance: "human", revision: 1, image: {source_pdf: "/lib/paper.pdf", page: 1, rectangle: {x: 72, y: 60, width: 180, height: 45, unit: "pt"}}},
                {id: "legacy", body: "Old screenshot clip", project_id: null, labels: [], provenance: "human", revision: 1, image: {source_pdf: "/lib/paper.pdf", page: 1, rectangle: {x: 10, y: 10, width: 400, height: 300}}},
                {id: "other", body: "Another PDF", project_id: null, labels: [], provenance: "human", revision: 1, image: {source_pdf: "/lib/supplement.pdf", page: 1, rectangle: {x: 72, y: 60, width: 180, height: 45, unit: "pt"}}}
            ]
            try {
            app.selected = r
            app.detailTab = "notes"
            app.paperTabs = [{id: r.id, citekey: r.citekey, title: r.title, view: "pdf", detail_tab: "notes", page: 2, zoom_mode: "width", zoom: 1}]
            app.activeTab = 0
            readerSheet.visible = true
            reader.tab = app.activePaper
            tryCompare(reader, "status", "ready")
            compare(reader.doc.page_count, 3)
            tryCompare(reader, "currentPage", 2)
            tryVerify(function () { return app.calls.indexOf("pdf_render:2") >= 0 }, 2000, "the restored page renders: " + app.calls)
            // A wheel notch scrolls one fixed step, quick notches add up, and
            // nothing keeps moving after them.
            var flick = find(reader, "readerPages")
            reader.goToPage(1)
            var start = flick.contentY, step = 3 * ui.space(24)
            mouseWheel(flick, flick.width / 2, flick.height / 2, 0, -120)
            mouseWheel(flick, flick.width / 2, flick.height / 2, 0, -120)
            wait(400)
            fuzzyCompare(flick.contentY - start, 2 * step, 1, "two notches scroll two steps")
            mouseWheel(flick, flick.width / 2, flick.height / 2, 0, 120)
            wait(400)
            fuzzyCompare(flick.contentY - start, step, 1, "one notch back up")
            // Ctrl+wheel zooms 10% a notch around the pointer.
            var z0 = reader.zoom, vx = flick.width * 0.3, vy = flick.height * 0.4
            var spot = reader.spotAt(vx, vy)
            mouseWheel(flick, vx, vy, 0, 120, Qt.NoButton, Qt.ControlModifier)
            fuzzyCompare(reader.zoom, z0 * 1.1, 0.001, "a notch zooms 10%")
            var kept = reader.spotAt(vx, vy)
            compare(kept.page, spot.page)
            fuzzyCompare(kept.x, spot.x, 0.5, "the spot under the pointer stays: x")
            fuzzyCompare(kept.y, spot.y, 0.5, "the spot under the pointer stays: y")
            mouseWheel(flick, vx, vy, 0, -120, Qt.NoButton, Qt.ControlModifier)
            fuzzyCompare(reader.zoom, z0, 0.001, "and back")
            // Middle-drag pans with the pointer, without selecting text.
            reader.goToPage(1)
            var y1 = flick.contentY
            mousePress(flick, 200, 400, Qt.MiddleButton)
            mouseMove(flick, 200, 330, -1, Qt.MiddleButton)
            mouseMove(flick, 200, 250, -1, Qt.MiddleButton)
            mouseRelease(flick, 200, 250, Qt.MiddleButton)
            fuzzyCompare(flick.contentY - y1, 150, 1, "middle-drag pans")
            compare(reader.selection, null)
            reader.setZoomMode("width")
            compare(reader.clips.length, 1, "only pt clips from this PDF are drawn")

            // Keyboard navigation.
            reader.forceActiveFocus()
            keyClick("G")
            compare(reader.currentPage, 3)
            keyClick("g"); keyClick("g")
            compare(reader.currentPage, 1)
            keyClick("2"); keyClick("G")
            compare(reader.currentPage, 2)
            keyClick("g"); keyClick("g")
            var y = find(reader, "readerPages").contentY
            keyClick("j")
            verify(find(reader, "readerPages").contentY > y, "j scrolls down")

            // Page pixels to PDF points depend on zoom only.
            reader.setZoom(1.5)
            compare(reader.zoom, 1.5)
            var pt = reader.toPoints(1, 150, 300, 300, 75)
            compare(pt.x, 100); compare(pt.y, 200); compare(pt.width, 200); compare(pt.height, 50)
            var back = reader.fromPoints(1, [100, 200, 300, 250])
            compare(back.x, 150); compare(back.width, 300)
            reader.setZoomMode("width")
            wait(250)

            // Text selection copies words; paragraphs stay apart.
            tryVerify(function () { return !!reader.words[1] })
            reader.selection = {page: 1, from: 0, to: 3}
            compare(reader.selectionText(), "Sparse attention\n\nTable headline")
            verify(reader.wantsEscape)
            keyClick(Qt.Key_C, Qt.ControlModifier)
            verify(app.calls.indexOf("copy:Sparse attention\n\nTable headline") >= 0, app.calls)
            keyClick(Qt.Key_Escape)
            compare(reader.selection, null)

            // `c` asks the chat about the selection.
            reader.selection = {page: 1, from: 0, to: 1}
            keyClick("c")
            compare(app.chatAttachment.selection.text, "Sparse attention")
            compare(app.detailTab, "chat")
            wait(100)
            shot("11c-reader-chat")
            compare(reader.selection, null)
            app.chatAttachment = null
            app.detailTab = "notes"
            // `c` moved focus into the chat box; Escape there hands it back (focusActiveTab).
            reader.focusPages()

            // Search jumps to the first hit.
            reader.goToPage(1)
            reader.runSearch("headline")
            tryVerify(function () { return reader.search && reader.search.flat.length === 1 })
            compare(reader.currentPage, 2)
            keyClick(Qt.Key_Escape)
            compare(reader.search, null)

            // An internal link jumps to its page.
            reader.goToPage(1)
            wait(100)
            var page1 = find(reader, "readerPage1")
            var mouse1 = find(page1, "readerPageMouse")
            mouseClick(mouse1, 100 * reader.zoom, 315 * reader.zoom)
            compare(reader.currentPage, 3, "link to page 3")

            // The clip tool: drag a rectangle, get a clip in points with a preview.
            reader.goToPage(1)
            wait(100)
            reader.forceActiveFocus()
            keyClick("r")
            compare(reader.tool, "rect")
            shot("11-reader-clip-tool")
            var z = reader.zoom
            mouseDrag(mouse1, 60 * z, 120 * z, 240 * z, 60 * z)
            tryVerify(function () { return app.lastClip !== null })
            compare(reader.tool, "select")
            compare(app.lastClip.page, 1)
            compare(app.lastClip.source_pdf, "/lib/paper.pdf")
            verify(Math.abs(app.lastClip.rect_pt.x - 60) < 1 && Math.abs(app.lastClip.rect_pt.width - 240) < 2, JSON.stringify(app.lastClip.rect_pt))
            verify(!!app.lastClip.preview, "the preview crops the rendered page")
            // A plain click with the tool is a page note; `a` does the same.
            app.lastClip = null
            keyClick("a")
            compare(app.lastClip.page, 1)
            verify(!app.lastClip.rect_pt)

            // Clicking a saved clip edits its note.
            mouseClick(mouse1, 100 * z, 80 * z)
            verify(app.calls.indexOf("edit:note:clip1") >= 0, app.calls)

            // Notes are written in the side pane, with the pending clip outlined on its page.
            app.composer = {note: null, clip: {source_pdf: "/lib/paper.pdf", page: 1, rect_pt: {x: 72, y: 280, width: 300, height: 90},
                preview: {path: String(Qt.resolvedUrl("math/display.svg")).replace(/^file:\/\//, ""), rect: Qt.rect(0, 0, 90, 40)}},
                token: "t1", projectId: "p-grl", labels: "", evidence: "PDF p. 1"}
            var composer = find(reader, "noteComposer")
            tryVerify(function () { return composer.visible })
            verify(reader.wantsEscape)
            var editorArea = find(composer, "noteEditorArea")
            tryVerify(function () { return editorArea.activeFocus }, 1000, "the composer takes focus")
            keyClick("O"); keyClick("k")
            shot("11c-reader-composer")
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            compare(app.saved.body, "Ok")
            compare(app.saved.projectId, "p-grl", "scope starts at the current project")
            compare(app.saved.evidence, "PDF p. 1")
            keyClick(Qt.Key_Escape)
            compare(app.composer, null)
            verify(!composer.visible)

            reader.showOutline = true
            wait(150)
            shot("11b-reader")

            // Theme colors: paper becomes the theme background, ink its text color,
            // colored ink keeps its hue. The toolbar button switches.
            reader.showOutline = false
            reader.setZoom(1)
            reader.goToPage(1)
            wait(300)
            var sheet = find(find(reader, "readerPage1"), "readerSheet")
            var viewport = find(reader, "readerPages")
            // Sample the window at a point given in the fixture page's pixels (306 x 396).
            var sample = function (image, x, y) {
                var p = sheet.mapToItem(stage, x * sheet.width / 306, y * sheet.height / 396)
                var inView = viewport.mapToItem(stage, 0, 0)
                verify(p.y >= inView.y && p.y < inView.y + viewport.height, "sample point on screen: " + p.y)
                return image.pixel(p.x, p.y)
            }
            var original = grabImage(stage)
            var white = sample(original, 20, 20)
            verify(white.r > 0.95 && white.g > 0.95 && white.b > 0.95, "original paper is white: " + white)
            mouseClick(find(reader, "readerColorsButton"))
            compare(app.settings.pdf_colors, "theme")
            var colors = find(find(reader, "readerPage1"), "readerPageColors")
            tryVerify(function () { return colors.visible })
            wait(250)
            // The software renderer (plain QT_QPA_PLATFORM=offscreen) skips ShaderEffects;
            // run with QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl to check the pixels.
            if (stage.GraphicsInfo.api === GraphicsInfo.Software) {
                console.warn("Software scene graph: theme page colors not rendered, pixel checks skipped")
                mouseClick(find(reader, "readerColorsButton"))
                compare(app.settings.pdf_colors, "original")
                return
            }
            var themed = grabImage(stage)
            var near = function (a, b) { return Math.abs(a.r - b.r) < 0.04 && Math.abs(a.g - b.g) < 0.04 && Math.abs(a.b - b.b) < 0.04 }
            shot("11d-reader-theme-colors")
            // Ink away from the saved clip's outline on the first line.
            var paper = sample(themed, 20, 20), ink = sample(themed, 200, 62)
            var link = sample(themed, 100, 204), figure = sample(themed, 150, 270)
            verify(near(paper, ui.pageBackground), "paper takes the theme background: " + paper + " vs " + ui.pageBackground)
            verify(near(ink, ui.pageText), "ink takes the theme text color: " + ink + " vs " + ui.pageText)
            verify(link.b > link.r + 0.1 && link.b > link.g + 0.05, "a blue link stays blue: " + link)
            verify(figure.r > figure.g + 0.1 && figure.r > figure.b + 0.1, "a red figure stays red: " + figure)
            mouseClick(find(reader, "readerColorsButton"))
            compare(app.settings.pdf_colors, "original")
            } finally {
                reader.showOutline = false
                readerSheet.visible = false
                reader.tab = null
                app.paperTabs = []
                app.activeTab = -1
            }
        }
        function test_11b_highlights() {
            function callsNamed(method) {
                var n = 0
                for (var i = 0; i < app.rpcLog.length; i++) if (app.rpcLog[i].method === method) n++
                return n
            }
            function findShown(name) {
                var top = stage
                while (top.parent) top = top.parent
                return find(top, name)
            }
            function near(got, want) { return Math.abs(got - want) < 0.01 }
            var r = Fixture.ref
            app.selected = r
            app.detailTab = "notes"
            app.highlightStore = ({})
            app.highlightSeq = 0
            app.rpcLog = []
            app.paperTabs = [{id: r.id, citekey: r.citekey, title: r.title, view: "pdf", detail_tab: "notes", page: 1, zoom_mode: "custom", zoom: 1}]
            app.activeTab = 0
            readerSheet.visible = true
            reader.tab = app.activePaper
            try {
                tryCompare(reader, "status", "ready")
                tryVerify(function () { return !!reader.words[1] })
                reader.setZoom(1)
                compare(reader.zoom, 1)
                wait(50)
                var mouse1 = find(find(reader, "readerPage1"), "readerPageMouse")
                verify(mouse1 !== null)

                var menuOpen = function () { return reader.contextMenuOpen }
                var choose = function (key) {
                    var row = findShown("menuItem:" + key) || findShown("menuSwatch:" + key)
                    verify(row !== null, "menu entry " + key)
                    // Rows are laid out on the next frame after the menu's entries change.
                    tryVerify(function () { return row.width > 0 })
                    mouseClick(row)
                    tryVerify(function () { return !reader.contextMenuOpen })
                }
                var rightClick = function (x, y) {
                    mouseClick(mouse1, x, y, Qt.RightButton)
                    tryVerify(menuOpen)
                }

                // A click on empty text does nothing.
                mouseClick(mouse1, 400, 200)
                wait(50)
                compare(callsNamed("add_highlight"), 0)
                compare(reader.selection, null)

                // With the select tool a double-click or a drag only selects.
                mouseDoubleClickSequence(mouse1, 198, 137)
                compare(reader.selection.from, 3)
                compare(reader.selection.to, 3)
                mouseDrag(mouse1, 91, 137, 110, 0)
                compare(Math.min(reader.selection.from, reader.selection.to), 2)
                compare(Math.max(reader.selection.from, reader.selection.to), 3)
                wait(50)
                compare(callsNamed("add_highlight"), 0)
                compare(reader.highlights.length, 0)

                // Right-clicking the selection copies it plain or as a cited Markdown quote.
                rightClick(100, 137)
                verify(findShown("menuItem:chat") !== null)
                verify(findShown("menuItem:highlight") !== null)
                verify(findShown("menuSwatch:highlight:purple") !== null)
                shot("11e-reader-selection-menu")
                choose("copy")
                verify(app.calls.indexOf("copy:Table headline") >= 0, app.calls)
                verify(reader.selection !== null, "copying keeps the selection")
                rightClick(100, 137)
                choose("markdown")
                verify(app.calls.indexOf("copy:> Table headline\n>\n> [@okafor_sparse_2026, p. 1]") >= 0, app.calls)

                // A swatch highlights the selection in that color, which the highlighter then takes.
                rightClick(100, 137)
                choose("highlight:green")
                tryVerify(function () { return reader.highlights.length === 1 })
                var table = reader.highlights[0]
                compare(table.color, "green")
                compare(table.quote, "Table headline")
                compare(table.rects.length, 1)
                verify(near(table.rects[0][0], 72) && near(table.rects[0][2], 221))
                verify(near(table.rects[0][1], 129) && near(table.rects[0][3], 145))
                compare(reader.selection, null)
                compare(reader.highlightColor, "green")
                var sent = app.rpcLog.filter(function (c) { return c.method === "add_highlight" })
                compare(sent[0].params.color, "green")
                compare(sent[0].params.attachment_id, "a1")
                verify(find(find(reader, "readerPage1"), "readerHighlight") !== null)

                // `m` picks up the highlighter: a drag saves in its color, a double-click saves a word.
                keyClick("m")
                compare(reader.tool, "highlight")
                verify(find(reader, "readerHighlightTool").active)
                mouseDrag(mouse1, 80, 82, 160, 0)
                tryVerify(function () { return reader.highlights.length === 2 })
                compare(reader.highlights[1].quote, "Sparse attention")
                compare(reader.highlights[1].color, "green")
                compare(reader.selection, null)
                compare(reader.tool, "highlight", "the highlighter stays in hand")
                keyClick("m")
                compare(reader.tool, "select")

                // A highlight's own menu recolors it and quotes it into the chat.
                rightClick(100, 137)
                verify(findShown("menuItem:delete") !== null)
                verify(findShown("menuItem:comment") !== null)
                choose("color:purple")
                tryVerify(function () { return reader.highlights[0].color === "purple" })
                compare(reader.highlights[1].color, "green")
                rightClick(100, 137)
                choose("chat")
                compare(app.chatAttachment.selection.text, "Table headline")
                compare(app.chatAttachment.selection.page, 1)
                compare(app.detailTab, "chat")
                app.chatAttachment = null

                // "Add a note about this" opens a page note that starts with the quote.
                app.composer = {note: null, clip: {source_pdf: "/lib/paper.pdf", page: 1}, token: "t2", projectId: null, labels: "", evidence: "PDF p. 1"}
                rightClick(100, 137)
                choose("note")
                compare(app.lastClip.source_pdf, "/lib/paper.pdf")
                compare(app.lastClip.page, 1)
                verify(!app.lastClip.rect_pt)
                compare(app.composer.body, "> Table headline\n\n")
                app.cancelComposer()

                // The side pane lists the highlights in reading order.
                app.detailTab = "notes"
                reader.sideHighlights = true
                var list = find(reader, "readerHighlights")
                tryVerify(function () { return list.visible })
                compare(list.marks.length, 2)
                compare(list.marks[0].quote, "Sparse attention")
                compare(list.marks[1].quote, "Table headline")
                wait(100)
                shot("11f-reader-highlights")
                var cards = []
                var collect = function (item) {
                    if (item.objectName === "highlightCard") cards.push(item)
                    for (var i = 0; i < item.children.length; i++) collect(item.children[i])
                }
                collect(list.contentItem)
                compare(cards.length, 2)
                mouseClick(cards[1])
                compare(reader.focusMark, list.marks[1].id)
                mouseClick(cards[0], 20, 10, Qt.RightButton)
                tryVerify(menuOpen)
                choose("delete")
                tryVerify(function () { return reader.highlights.length === 1 })
                compare(reader.highlights[0].quote, "Table headline")
                // Asking for another section gives the side pane back.
                app.detailTab = "overview"
                verify(!reader.sideHighlights)
                app.detailTab = "notes"

                // A click on a highlight still opens the popover: comment and delete.
                mouseClick(mouse1, 91, 137)
                tryVerify(function () { return reader.highlightMenuOpen })
                mouseClick(findShown("highlightSwatchRed"))
                tryVerify(function () { return reader.highlights[0].color === "red" })
                var field = findShown("highlightComment")
                mouseClick(field)
                field.forceActiveFocus()
                keyClick(Qt.Key_N); keyClick(Qt.Key_O); keyClick(Qt.Key_T); keyClick(Qt.Key_E)
                keyClick(Qt.Key_Return)
                tryVerify(function () { return reader.highlights[0].comment === "note" })
                mouseClick(findShown("highlightDelete"))
                tryVerify(function () { return reader.highlights.length === 0 && !reader.highlightMenuOpen })

                // On bare page the menu offers a page note, a clip and the highlighter.
                rightClick(400, 300)
                verify(findShown("menuItem:pageNote") !== null)
                verify(findShown("menuItem:clip") !== null)
                choose("tool")
                compare(reader.tool, "highlight")
                keyClick(Qt.Key_Escape)
                compare(reader.tool, "select")
            } finally {
                reader.sideHighlights = false
                reader.tool = "select"
                readerSheet.visible = false
                reader.tab = null
                app.paperTabs = []
                app.activeTab = -1
            }
        }
        function test_12_chat_pane() {
            var ref = Fixture.ref
            app.selected = ref
            app.detailTab = "chat"
            var store = {}
            store["chat-1"] = {chat: {id: "chat-1", ref_id: ref.id, agent: "claude", agent_label: "Claude Code", resumable: true}, events: [], draft: "", status: "idle", busy: false, lastSeq: 0}
            app.chats = store
            var owners = {}
            owners[ref.id] = "chat-1"
            app.chatForRef = owners
            app.chatRevision++
            wait(100)
            var transcript = find(detail, "chatTranscript")
            verify(transcript, "chat transcript")
            compare(transcript.count, 0)

            app.pushChat("chat-1", "user", {text: "What does Table 2 show?", selection: {page: 6, text: "Table 2 reports the headline result"}})
            app.pushChat("chat-1", "session", {agent: "claude", version: "2.1.272", model: "claude-opus-5"})
            app.pushChat("chat-1", "assistant", {text: "Let me read the reference first."})
            app.pushChat("chat-1", "tool_call", {id: "t1", name: "mcp__omabib__get_reference", input: {id: "r2"}})
            app.pushChat("chat-1", "tool_result", {id: "t1", output: "{\"title\":\"Sparse\"}", is_error: false})
            app.pushChat("chat-1", "assistant", {text: "Table 2 compares **dense** and sparse attention on p. 6: sparse stays within 2%. :codex-file-citation{path=\"/papers/sparse.pdf\" purpose=\"source\"}"})
            app.pushChat("chat-1", "turn_end", {interrupted: false, is_error: false, usage: {input_tokens: 6, cache_read_input_tokens: 20412, output_tokens: 389}})
            app.pushChat("chat-1", "approval", {request_id: "q1", tool: "mcp__omabib__add_note", input: {body: "Sparse stays within 2% (Table 2)", project_id: null}, source: "omabib"})
            app.chats["chat-1"].busy = true
            app.chats["chat-1"].status = "approval"
            app.chatRevision++
            app.chatDraft = "I'll save the note once you **approve** it."
            wait(250)
            compare(transcript.count, 7, "a tool result joins its call")
            // Steps are hidden by default: the session line, the message written
            // before a tool call, and the call itself take no space.
            compare(app.chatStepsShown, false)
            for (var i = 1; i <= 3; i++) compare(transcript.itemAtIndex(i).height, 0, "step row " + i + " is hidden")
            verify(transcript.itemAtIndex(0).height > 0 && transcript.itemAtIndex(4).height > 0)
            var answer = find(detail, "chatAnswer")
            verify(answer.text.indexOf("omabib-page:6") >= 0, "page references link to the reader")
            verify(answer.text.indexOf("omabib-file:%2Fpapers%2Fsparse.pdf") >= 0 && answer.text.indexOf("codex-file-citation") < 0, answer.text)
            verify(answer.getText(0, answer.length).indexOf("sparse.pdf") >= 0, "a citation reads as the file name")
            mouseClick(find(detail, "chatCopy"))
            verify(app.calls.indexOf("copy:Table 2 compares **dense** and sparse attention on p. 6: sparse stays within 2%.") >= 0, app.calls)
            compare(find(detail, "chatModel").text, "Opus", "the default model is named")
            answer.openLink("omabib-page:6")
            verify(app.calls.indexOf("openChatLink:omabib-page:6") >= 0, app.calls)
            var draft = find(detail, "chatDraft")
            tryVerify(function () { return draft.visible && draft.getText(0, draft.length).indexOf("approve") >= 0 }, 1000, "the streaming draft renders")
            shot("12-chat")
            mouseClick(find(detail, "chatSteps"))
            compare(app.settings.chat_steps, "shown")
            tryVerify(function () { return transcript.itemAtIndex(3).height > 0 }, 1000, "the tool call shows with steps on")
            shot("12c-chat-steps")
            mouseClick(find(detail, "chatSteps"))
            tryVerify(function () { return transcript.itemAtIndex(3).height === 0 }, 1000)

            // The model menu: Down from Default picks the first listed model.
            mouseClick(find(detail, "chatModel"))
            wait(100)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            verify(app.calls.indexOf("setChatModel:claude:opus:") >= 0, app.calls)

            mouseClick(find(detail, "chatAllow"))
            verify(app.calls.indexOf("approveChat:q1:true") >= 0, app.calls)
            app.pushChat("chat-1", "approval_result", {request_id: "q1", allow: true})
            wait(50)
            verify(!find(detail, "chatAllow").visible, "an answered request hides its buttons")

            // Enter sends only when no reply is running.
            app.chats["chat-1"].busy = false
            app.chatRevision++
            app.chatDraft = ""
            var input = find(detail, "chatInput")
            input.forceActiveFocus()
            input.text = "Thanks"
            keyClick(Qt.Key_Return)
            verify(app.calls.indexOf("sendChat:Thanks") >= 0, app.calls)
            compare(input.text, "")

            // While steps are hidden, the current one shows beside the typing dots.
            app.pushChat("chat-1", "user", {text: "Thanks"})
            app.chats["chat-1"].busy = true
            app.chatRevision++
            app.pushChat("chat-1", "tool_call", {id: "t2", name: "shell", input: {command: "pdftotext paper.pdf -"}})
            var activity = find(detail, "chatActivity")
            tryVerify(function () { return activity.visible }, 1000, "activity line")
            compare(activity.text, "Ran `pdftotext paper.pdf -`")
            app.chats["chat-1"].busy = false
            app.chatRevision++

            // A selection from the reader rides along as a chip.
            app.askAboutSelection(6, "Table 2 reports the headline result")
            wait(50)
            verify(find(detail, "chatAttachment").visible)
            shot("12b-chat-attachment")
            app.chatAttachment = null
            app.chats = ({})
            app.chatForRef = ({})
            app.chatRevision++
        }
        function test_14_sync_panel() {
            syncSheet.visible = true
            var providers = [
                {id: "drive", label: "Google Drive", folder: "My Drive → Omabib", available: false, blocked: "Waiting for Omabib's Google app registration"},
                {id: "dropbox", label: "Dropbox", folder: "Dropbox → Omabib", available: false},
                {id: "onedrive", label: "OneDrive", folder: "OneDrive → Omabib", available: false},
                {id: "folder", label: "A folder on this computer", folder: "Syncthing, Nextcloud or Dropbox's app keeps it in sync", available: true},
                {id: "rclone", label: "Other (advanced)", folder: "S3, R2, B2, WebDAV or anything rclone reaches", available: false}
            ]
            // Choosing where, before rclone is installed.
            app.syncStatus = {connected: false, configured: false, state: "off"}
            app.syncProviders = {rclone: {installed: false}, providers: providers}
            wait(80)
            verify(find(syncPanel, "syncChoose").visible)
            verify(find(syncPanel, "syncInstallRclone").visible)
            shot("14a-sync-choose")
            mouseClick(find(syncPanel, "syncInstallRclone"))
            verify(app.calls.indexOf("installRclone") >= 0, app.calls)
            mouseClick(find(syncPanel, "syncProvider:folder"))
            wait(50)
            verify(find(syncPanel, "syncFolder").visible)
            compare(find(syncPanel, "syncFolder").text, "/home/reader/Sync")
            shot("14b-sync-folder")
            // With rclone, the cloud cards work.
            app.syncProviders = {rclone: {installed: true, version: "v1.75.1", remotes: []}, providers: providers.map(function (p) { return Object.assign({}, p, {available: p.id !== "drive"}) })}
            wait(50)
            verify(!find(syncPanel, "syncInstallRclone").visible)
            mouseClick(find(syncPanel, "syncProvider:dropbox"))
            verify(app.calls.indexOf("connectSync:dropbox:") >= 0, app.calls)
            mouseClick(find(syncPanel, "syncProvider:drive"))
            verify(app.calls.indexOf("connectSync:drive:") < 0, "Drive waits for its Google app")

            // Signing in.
            app.syncStatus = {connected: false, configured: false, state: "off", connecting: {provider: "dropbox", label: "Dropbox", state: "browser", url: "http://127.0.0.1:53682/auth?state=x"}}
            wait(50)
            verify(find(syncPanel, "syncConnecting").visible)
            shot("14c-sync-connecting")
            mouseClick(find(syncPanel, "syncCancelConnect"))
            verify(app.calls.indexOf("cancelSyncConnect") >= 0)

            // Connected: a library is already there.
            app.syncStatus = {connected: true, configured: false, state: "off", where: "Dropbox → Omabib", provider: {kind: "rclone", provider: "dropbox", label: "Dropbox"}}
            app.syncFound = {exists: true, counts: {references: 1617, notes: 13, pdfs: 17}, last_device: "laptop-omarchy", last_updated: new Date(Date.now() - 240000).toISOString(), local: {references: 0, notes: 0, pdfs: 0}}
            wait(50)
            verify(find(syncPanel, "syncJoin").visible && !find(syncPanel, "syncMerge").visible)
            shot("14d-sync-join")
            mouseClick(find(syncPanel, "syncJoin"))
            verify(app.calls.indexOf("startSync:join") >= 0)
            app.syncFound = Object.assign({}, app.syncFound, {local: {references: 40, notes: 2, pdfs: 1}})
            wait(50)
            verify(find(syncPanel, "syncMerge").visible && find(syncPanel, "syncReplace").visible && !find(syncPanel, "syncJoin").visible)
            shot("14e-sync-merge")
            app.syncFound = {exists: false, local: {references: 1617, notes: 13, pdfs: 17}}
            wait(50)
            verify(find(syncPanel, "syncStart").visible)
            shot("14f-sync-new")
            mouseClick(find(syncPanel, "syncStart"))
            verify(app.calls.indexOf("startSync:new") >= 0)

            // Syncing, with things to review.
            app.syncStatus = {connected: true, configured: true, state: "idle", where: "Dropbox → Omabib", provider: {kind: "rclone", provider: "dropbox", label: "Dropbox"},
                last_success: new Date(Date.now() - 120000).toISOString(), pending: 0, conflicts: 3,
                devices: [{device: "a", name: "laptop-omarchy", updated: new Date(Date.now() - 120000).toISOString(), me: true}, {device: "b", name: "desktop", updated: new Date(Date.now() - 3600000).toISOString(), me: false}],
                pdfs: {here: 12, cloud_only: 5}}
            app.syncConflicts = [
                {id: "c1", kind: "note_copy", ref_id: "r1", summary: "A note on “Sparse attention” was also edited on desktop"},
                {id: "c2", kind: "deleted", ref_id: "r2", summary: "“Tidal coupling” was deleted on desktop after you changed it here"},
                {id: "c3", kind: "duplicate", ref_id: "r3", summary: "“Same paper” may be the same paper as “Same paper” (same DOI)"}
            ]
            wait(80)
            verify(find(syncPanel, "syncStatusPage").visible)
            verify(find(syncPanel, "syncDownloadAll").visible)
            shot("14g-sync-status")
            mouseClick(find(syncPanel, "syncNow"))
            verify(app.calls.indexOf("syncNow") >= 0)
            app.syncStatus = Object.assign({}, app.syncStatus, {state: "auth"})
            wait(50)
            mouseClick(find(syncPanel, "syncNow"))
            verify(app.calls.indexOf("reconnectSync") >= 0, "an expired sign-in offers Reconnect")
            syncSheet.visible = false
            app.syncStatus = ({})
            app.syncConflicts = []
            app.syncFound = null
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
