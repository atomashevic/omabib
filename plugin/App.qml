import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Qt.labs.folderlistmodel
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import "components"
import "components/Format.js" as Format

Item {
    id: root
    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool expanded: false
    property var projects: []
    property var hits: []
    property string browseSort: "added_desc"
    // "", "missing_abstract" or "missing_pdf": the rail's needs-attention views.
    property string attentionView: ""
    property var selected: null
    property string lastSelectedId: ""
    // overview | ai | notes | files | bibtex
    property string detailTab: "overview"
    readonly property var detailTabs: ["overview", "ai", "notes", "files", "bibtex"]
    property var deletePreview: null
    property bool deleteBusy: false
    property int deleteRequest: -1
    property var noteDeletePreview: null
    property bool noteDeleteBusy: false
    property int noteDeleteRequest: -1
    property string pendingOpenRefId: ""
    property bool codexBusy: false
    property string noteTargetId: ""
    property string noteTargetTitle: ""
    property int noteSaveRequest: -1
    property bool noteSaving: false
    // A note being written in a reader tab's side pane; see NoteComposer.
    property var composer: null
    property bool composerSaving: false
    property string composerError: ""
    // Error callbacks for requests that handle their own failures, by request id.
    property var rpcErrors: ({})
    // Bumped on every (re)connection, so views waiting on lost replies can start over.
    property int connectionEpoch: 0
    property string projectId: ""
    property string serviceSocket: Quickshell.env("OMABIB_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/omabib/socket")
    readonly property string pdfShortcut: Quickshell.env("OMABIB_PDF_SHORTCUT") || "Ctrl+O"
    readonly property string homeDir: Quickshell.env("HOME") || ""
    property string projectName: "All references"
    property string assignTargetId: ""
    // The AI summary tab's overview: idle | loading | ready | unavailable | error.
    property string overviewRefId: ""
    property string overviewBody: ""
    property string overviewUrl: ""
    property string overviewState: "idle"
    property string overviewFetchedAt: ""
    property bool overviewCached: false
    property string overviewMessage: ""
    property bool overviewBusy: false
    property string overviewRequestId: ""
    property bool allNotes: false
    property bool includeOtherNotes: false
    // note id -> data: URL of its PDF clip, loaded when its card is shown.
    property var noteImages: ({})
    property var noteImageRequests: ({})
    property string error: ""
    property string notice: ""
    property int sequence: 0
    property int searchSequence: 0
    property var pending: ({})
    property int pendingSearch: -1
    property string editToken: ""
    property var nextCursor: null
    property int referenceCount: 0
    property string editKind: ""
    property var editingNote: null
    property var pendingImport: null
    property bool previewShowBibtex: false
    property real openedAt: 0
    property real searchedAt: 0
    property real lastPaintMs: -1
    property real responseMs: 0
    property real lastInputAt: 0
    property real paintStartedAt: 0
    property real openMs: -1
    property bool searchPending: false
    property bool paintPending: false
    property bool openPending: false
    property bool candidatesLimited: false
    property string actionDigits: ""
    property string importPath: ""
    property bool importingFile: false
    property string pickerKind: "bib"
    property string attachmentRefId: ""
    property var metadataLookup: null
    property var metadataChoice: null
    property bool metadataBusy: false
    property int metadataRequest: -1
    property string metadataInfo: ""
    property var repoSettings: ({})
    property var repoStatus: ({})
    property var repoCheck: ({})
    property bool syncBusy: false
    property bool repoBusy: false
    property int syncRequest: -1
    // Preferences from omabib-settings: {ai_cli, ai_desktop}, plus
    // the installed choices the Settings dialog offers.
    property var settings: ({ai_cli: "codex", ai_desktop: "chatgpt"})
    property var settingsInfo: null
    property bool settingsBusy: false
    property var settingsQueue: []
    // Paper tabs: opened beside the library tab, sticky until closed, at most
    // maxTabs, and kept per library socket in $XDG_STATE_HOME/omabib/tabs.json.
    readonly property int maxTabs: 12
    property var paperTabs: []
    property int activeTab: -1
    readonly property bool inPaperTab: activeTab >= 0 && activeTab < paperTabs.length
    readonly property var activePaper: inPaperTab ? paperTabs[activeTab] : null
    // Tab identity: a reference can be open both as a paper tab and as a PDF tab.
    readonly property var tabIds: paperTabs.map(function(t){return tabKey(t)})
    readonly property bool inPdfTab: inPaperTab && activePaper.kind==="pdf"
    // The library tab's detail while a paper tab is showing.
    property var searchView: ({selected: null, detailTab: "overview"})
    property var paperCache: ({})
    property var overviewCache: ({})
    // Rendered LaTeX for Markdown notes and overviews, by Markdown.mathKey:
    // {path, width, height} or {error}. Rendered in the reading color, so a
    // theme change starts over.
    property var mathCache: ({})
    property var mathQueued: ({})
    property var mathQueue: []
    property var mathRequests: ({})
    readonly property string mathColor: ui.css(ui.bright)
    onMathColorChanged: { mathCache=({}); mathQueued=({}); mathQueue=[] }
    property var tabsStore: ({})
    property bool tabsRestored: false
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omabib"
    readonly property string cliName: settings.ai_cli === "claude" ? "Claude Code" : "Codex"
    readonly property string desktopName: settings.ai_desktop === "claude" ? "Claude Desktop" : "ChatGPT"

    // The list pane owns these controls; the verbs below address them by
    // their old names.
    readonly property var query: listPane.queryField
    readonly property var results: listPane.resultsView
    readonly property var authorFilter: listPane.authorField
    readonly property var yearFilter: listPane.yearField
    readonly property var typeFilter: listPane.typeField
    readonly property var labelFilter: listPane.labelField
    readonly property string queryText: query ? query.text.trim() : ""
    readonly property bool filtersActive: !!(authorFilter && (authorFilter.text || yearFilter.text || typeFilter.text || labelFilter.text))
    readonly property bool overflowOpen: overflowMenu.opened
    readonly property bool modalOpen: settingsDialog.opened || editorDialog.opened || commandDialog.opened || projectDialog.opened || previewDialog.opened || bibFileDialog.opened || repoDialog.opened || metadataDialog.opened || deleteDialog.opened || noteDeleteDialog.opened || projectMenu.opened || attentionMenu.opened || overflowMenu.opened

    Theme {
        id: ui
        readingFamily: Quickshell.env("OMABIB_READING_FONT") || "Noto Sans"
    }

    component BibButton: Button {
        id: control
        property bool textLeft: false
        // outline | ghost | primary | danger
        property string variant: "outline"
        property string iconName: ""
        property string shortcutHint: ""
        readonly property color foreground: !enabled ? ui.dim : variant === "primary" ? ui.bright : variant === "danger" ? ui.urgent : control.hovered || control.activeFocus ? ui.bright : ui.text
        implicitHeight: ui.space(30)
        implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
        leftPadding: ui.space(12)
        rightPadding: ui.space(12)
        topPadding: 0
        bottomPadding: 0
        contentItem: Item {
            implicitWidth: buttonRow.implicitWidth
            implicitHeight: buttonRow.implicitHeight
            RowLayout {
                id: buttonRow
                anchors.verticalCenter: parent.verticalCenter
                x: control.textLeft ? 0 : Math.round((parent.width - width) / 2)
                width: control.textLeft ? parent.width : implicitWidth
                spacing: ui.space(7)
                Icon { theme: ui; visible: control.iconName !== ""; name: control.iconName; size: ui.body + 2; color: control.variant === "primary" ? ui.bright : control.variant === "danger" ? ui.urgent : control.enabled ? ui.muted : ui.dim }
                Text {
                    Layout.fillWidth: control.textLeft
                    text: control.text
                    color: control.foreground
                    font.family: ui.mono
                    font.pixelSize: ui.body
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Keycap { theme: ui; visible: control.shortcutHint !== ""; text: control.shortcutHint; onAccent: control.variant === "primary" }
            }
        }
        background: Rectangle {
            radius: ui.radius
            color: control.variant === "primary" ? (control.down ? Qt.darker(ui.accent, 1.15) : control.hovered ? Qt.lighter(ui.accent, 1.12) : ui.accent)
                : control.down ? ui.pressedFill : control.hovered ? ui.hoverFill : control.highlighted ? ui.line : "transparent"
            opacity: control.enabled ? 1 : 0.6
            border.width: control.activeFocus ? ui.focusBorderWidth : (control.variant === "outline" || control.variant === "danger") ? 1 : 0
            border.color: control.activeFocus ? ui.focusBorder : control.variant === "danger" ? Qt.rgba(ui.urgent.r, ui.urgent.g, ui.urgent.b, 0.6) : ui.controlBorder
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }
    component BibDialog: Dialog {
        id: dialog
        property string iconName: ""
        palette.window: ui.card
        palette.windowText: ui.text
        palette.base: ui.app
        palette.text: ui.bright
        palette.button: ui.card
        palette.buttonText: ui.text
        palette.highlight: ui.line
        palette.highlightedText: ui.bright
        palette.placeholderText: ui.dim
        font.family: ui.mono
        font.pixelSize: ui.body
        leftPadding: ui.space(20)
        rightPadding: ui.space(20)
        topPadding: ui.space(14)
        bottomPadding: ui.space(16)
        Overlay.modal: Rectangle { color: ui.scrim }
        background: Rectangle { color: ui.card; border.color: ui.border; border.width: 1; radius: ui.radius }
        header: Item {
            implicitHeight: ui.space(46)
            visible: dialog.title !== ""
            RowLayout {
                anchors { fill: parent; leftMargin: ui.space(20); rightMargin: ui.space(10) }
                spacing: ui.space(10)
                Icon { theme: ui; visible: dialog.iconName !== ""; name: dialog.iconName; size: ui.heading; color: ui.accentText }
                Text { Layout.fillWidth: true; text: dialog.title; color: ui.bright; font.family: ui.mono; font.pixelSize: ui.title; font.weight: Font.DemiBold; elide: Text.ElideRight; textFormat: Text.PlainText }
                IconButton { theme: ui; icon: "close"; iconColor: ui.dim; tooltip: "Close"; shortcut: "Esc"; onClicked: dialog.close() }
            }
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: ui.line }
        }
    }
    component BibLabel: Label {
        color: ui.text
        font.family: ui.mono
        font.pixelSize: ui.body
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    component BibField: TextField {
        id: field
        color: ui.bright
        placeholderTextColor: ui.dim
        selectionColor: Qt.rgba(ui.accent.r, ui.accent.g, ui.accent.b, 0.55)
        selectedTextColor: ui.bright
        font.family: ui.mono
        font.pixelSize: ui.body
        selectByMouse: true
        implicitHeight: ui.space(32)
        leftPadding: ui.space(10)
        rightPadding: ui.space(10)
        background: Rectangle {
            color: ui.app
            radius: ui.radius
            border.width: field.activeFocus ? ui.focusBorderWidth : 1
            border.color: field.activeFocus ? ui.focusBorder : ui.controlBorder
        }
    }
    component BibCombo: ComboBox {
        id: combo
        implicitHeight: ui.space(32)
        font.family: ui.mono
        font.pixelSize: ui.body
        contentItem: Text {
            leftPadding: ui.space(10)
            rightPadding: ui.space(28)
            text: combo.displayText
            color: combo.enabled ? ui.bright : ui.dim
            font: combo.font
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
        }
        indicator: Icon { theme: ui; x: combo.width - width - ui.space(10); anchors.verticalCenter: combo.verticalCenter; name: "chevronDown"; size: ui.title; color: ui.muted }
        background: Rectangle {
            color: ui.app
            radius: ui.radius
            border.width: combo.activeFocus ? ui.focusBorderWidth : 1
            border.color: combo.activeFocus ? ui.focusBorder : ui.controlBorder
        }
        delegate: ItemDelegate {
            id: option
            required property int index
            required property var modelData
            width: ListView.view ? ListView.view.width : combo.width
            implicitHeight: ui.space(30)
            highlighted: combo.highlightedIndex === index
            contentItem: Text { text: option.modelData; color: option.highlighted ? ui.bright : ui.text; font: combo.font; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter; textFormat: Text.PlainText }
            background: Rectangle { color: option.highlighted ? ui.line : "transparent" }
        }
        popup: Popup {
            y: combo.height + ui.space(2)
            width: combo.width
            implicitHeight: Math.min(contentItem.implicitHeight + ui.space(8), ui.space(320))
            padding: ui.space(4)
            contentItem: ListView { clip: true; implicitHeight: contentHeight; model: combo.popup.visible ? combo.delegateModel : null; currentIndex: combo.highlightedIndex }
            background: Rectangle { color: ui.card; border.width: 1; border.color: ui.controlBorder; radius: ui.radius }
        }
    }
    component BibTextArea: TextArea {
        id: area
        color: ui.bright
        placeholderTextColor: ui.dim
        selectionColor: Qt.rgba(ui.accent.r, ui.accent.g, ui.accent.b, 0.55)
        selectedTextColor: ui.bright
        font.family: ui.mono
        font.pixelSize: ui.body
        wrapMode: TextEdit.Wrap
        selectByMouse: true
        padding: ui.space(10)
        background: Rectangle {
            color: ui.app
            radius: ui.radius
            border.width: area.activeFocus ? ui.focusBorderWidth : 1
            border.color: area.activeFocus ? ui.focusBorder : ui.line
        }
    }

    component ErrorBanner: Rectangle {
        visible: root.error !== ""
        implicitHeight: bannerRow.implicitHeight + ui.space(14)
        color: Qt.rgba(ui.urgent.r, ui.urgent.g, ui.urgent.b, 0.12)
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 2; color: ui.urgent }
        RowLayout {
            id: bannerRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: ui.space(14); rightMargin: ui.space(6) }
            spacing: ui.space(10)
            Icon { theme: ui; name: "alert"; size: ui.title + 1; color: ui.urgent }
            Text { Layout.fillWidth: true; text: root.error; color: ui.bright; font.family: ui.mono; font.pixelSize: ui.body; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; textFormat: Text.PlainText }
            IconButton { theme: ui; icon: "close"; size: ui.space(24); iconSize: ui.title; iconColor: ui.muted; tooltip: "Dismiss"; onClicked: root.error = "" }
        }
    }

    function open(payloadJson) {
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
        if(editorDialog.opened) { activeEditor().forceActiveFocus(); return }
        if(payload.socket_path && payload.socket_path!==serviceSocket){saveTabs();resetOverview();overviewCache=({});socket.connected=false;serviceSocket=payload.socket_path;applyTabs();Qt.callLater(function(){socket.connected=true})}
        if(payload.action==="pdf" && payload.ref_id) { opened=true; if(socket.connected)refresh(); openPdfTabById(payload.ref_id); return }
        if(payload.ref_id || payload.query!==undefined || payload.action==="add") activateTab(-1)
        pendingOpenRefId=payload.ref_id||""
        if(pendingOpenRefId){authorFilter.text="";yearFilter.text="";typeFilter.text="";labelFilter.text="";attentionView=""}
        if(payload.query!==undefined) query.text=payload.query
        if (payload.project_id !== undefined) projectId = payload.project_id || ""
        openedAt = Date.now()
        openPending = true
        opened = true
        if (socket.connected) refresh()
        else socket.connected = true
        Qt.callLater(function() { if(payload.action==="add"){closeMenus();commandDialog.close();bibFileDialog.close();metadataDialog.close();previewDialog.close();repoDialog.close();projectDialog.close();if(editorDialog.opened)activeEditor().forceActiveFocus();else edit("quick");}else if(root.inPaperTab){root.focusActiveTab()}else{query.forceActiveFocus(); query.selectAll()} })
    }
    function close() {
        opened = false
        closeMenus()
    }
    function closeMenus() {
        projectMenu.close();attentionMenu.close();overflowMenu.close()
    }
    // The reference the toolbar, palette and shortcuts act on: the active
    // paper tab's, or the library tab's current result.
    function targetRef() {
        if(inPaperTab) return selected && selected.id===activePaper.id ? selected : activePaper
        return currentHit()
    }
    function setSearchSelected(value) {
        if(inPaperTab) searchView=Object.assign({},searchView,{selected:value})
        else selected=value
    }
    function enterSearch() {
        activeTab=-1
        detailTab=searchView.detailTab||"overview"
        selected=searchView.selected
        searchView={selected:null,detailTab:"overview"}
        if(expanded && hits.length) showDetail()
        Qt.callLater(function(){if(!root.inPaperTab)query.forceActiveFocus()})
    }
    function enterPaper(index) {
        var tab=paperTabs[index]
        activeTab=index
        detailTab=tab.detail_tab||(tab.kind==="pdf"?"notes":"overview")
        selected=paperCache[tab.id]||null
        loadPaper(index)
        Qt.callLater(focusActiveTab)
    }
    function focusActiveTab() {
        if(!inPaperTab)return
        if(inPdfTab)readerPane.forceActiveFocus()
        else paperKeys.forceActiveFocus()
    }
    function tabKey(tab) { return (tab.kind==="pdf"?"pdf:":"")+tab.id }
    function activateTab(index) {
        if(index<-1 || index>=paperTabs.length)return
        closeMenus()
        if(index===activeTab){
            if(index<0)query.forceActiveFocus()
            else if(!selected)loadPaper(index)
            return
        }
        if(!inPaperTab) searchView={selected:selected,detailTab:detailTab}
        if(index<0) enterSearch()
        else enterPaper(index)
        saveTabs()
    }
    function cycleTopTab(delta) {
        var total=paperTabs.length+1
        activateTab((activeTab+1+delta+total)%total-1)
    }
    function loadPaper(index) {
        var tab=paperTabs[index]
        if(!tab || !socket.connected)return
        var id=tab.id
        rpc("get_reference",{id:id,project_id:projectId||null,include_notes:true,include_attachments:true,include_other_projects:includeOtherNotes,note_chars:65536},function(r){
            root.paperCache[id]=r
            for(var at=0;at<root.paperTabs.length;++at){
                var t=root.paperTabs[at]
                if(t.id===id && (t.title!==(r.title||r.citekey) || t.citekey!==r.citekey))root.updateTab(at,{title:r.title||r.citekey,citekey:r.citekey})
            }
            if(root.inPaperTab && root.activePaper.id===id)root.selected=r
        })
    }
    function updateTab(index, changes) {
        var tabs=paperTabs.slice()
        tabs[index]=Object.assign({},tabs[index],changes)
        paperTabs=tabs
        saveTabs()
    }
    // Opens a paper beside the library tab, or shows its existing tab.
    function openInTab(ref, background) {
        ref=ref||targetRef()
        if(!ref)return
        var at=tabIds.indexOf(ref.id)
        if(at>=0){
            if(background)flash(ref.citekey+" is already open in a tab")
            else activateTab(at)
            return
        }
        if(paperTabs.length>=maxTabs){flash(maxTabs+" tabs are open. Close one to open another.");return}
        var current=!inPaperTab && selected && selected.id===ref.id
        if(current)paperCache[ref.id]=selected
        paperTabs=paperTabs.concat([{id:ref.id,citekey:ref.citekey,title:ref.title||ref.citekey,detail_tab:current?detailTab:"overview"}])
        if(background){saveTabs();flash("Opened "+ref.citekey+" in a tab")}
        else activateTab(paperTabs.length-1)
    }
    // Opens a reference's PDF in a reader tab, or shows its existing reader tab.
    function openPdfTab(ref, background) {
        ref=ref||targetRef()
        if(!ref)return
        var at=tabIds.indexOf("pdf:"+ref.id)
        if(at>=0){ if(!background)activateTab(at); return }
        if(paperTabs.length>=maxTabs){flash(maxTabs+" tabs are open. Close one to open another.");return}
        if(selected && selected.id===ref.id)paperCache[ref.id]=selected
        paperTabs=paperTabs.concat([{id:ref.id,citekey:ref.citekey,title:ref.title||ref.citekey,kind:"pdf",detail_tab:"notes",page:1,zoom_mode:"width",zoom:1}])
        if(background)saveTabs()
        else activateTab(paperTabs.length-1)
    }
    function openPdfTabById(refId) {
        rpc("get_reference",{id:refId,include_metadata:false},function(r){root.openPdfTab(r,false)})
    }
    function closeTab(index) {
        if(index<0 || index>=paperTabs.length)return
        var closing=paperTabs[index]
        var tabs=paperTabs.slice()
        tabs.splice(index,1)
        if(!tabs.some(function(t){return t.id===closing.id}))delete paperCache[closing.id]
        closeMenus()
        if(index===activeTab){
            activeTab=-1
            paperTabs=tabs
            var next=index<tabs.length ? index : index-1
            if(next<0)enterSearch()
            else enterPaper(next)
        } else {
            var keep=activeTab>index ? activeTab-1 : activeTab
            paperTabs=tabs
            activeTab=keep
        }
        saveTabs()
    }
    function closeActiveTab() { if(inPaperTab)closeTab(activeTab) }
    function findInLibrary() {
        if(!inPaperTab)return
        focusOnReference(activePaper.citekey)
    }
    function saveTabs() {
        if(!tabsRestored)return
        var store=Object.assign({},tabsStore)
        if(paperTabs.length)store[serviceSocket]={tabs:paperTabs,active:activeTab}
        else delete store[serviceSocket]
        tabsStore=store
        tabsFile.setText(JSON.stringify({version:1,libraries:store},null,2)+"\n")
    }
    function restoreTabs(text) {
        if(tabsRestored)return
        var libraries={}
        try{
            var parsed=JSON.parse(text||"{}")
            if(parsed && parsed.libraries && typeof parsed.libraries==="object")libraries=parsed.libraries
        }catch(e){}
        tabsStore=libraries
        tabsRestored=true
        applyTabs()
    }
    // Shows the tabs saved for the current library socket.
    function applyTabs() {
        if(!tabsRestored)return
        var entry=tabsStore[serviceSocket]||{}
        var tabs=(Array.isArray(entry.tabs)?entry.tabs:[]).filter(function(t){return t && typeof t.id==="string" && typeof t.citekey==="string"})
            .slice(0,maxTabs).map(function(t){
                var tab={id:t.id,citekey:t.citekey,title:String(t.title||t.citekey),detail_tab:detailTabs.indexOf(t.detail_tab)>=0?t.detail_tab:"overview"}
                if(t.kind==="pdf"){tab.kind="pdf";tab.page=Number.isInteger(t.page)&&t.page>0?t.page:1;tab.zoom_mode=["width","page","custom"].indexOf(t.zoom_mode)>=0?t.zoom_mode:"width";tab.zoom=typeof t.zoom==="number"&&t.zoom>0?t.zoom:1}
                return tab
            })
        if(inPaperTab){activeTab=-1;selected=searchView.selected;detailTab=searchView.detailTab||"overview";searchView={selected:null,detailTab:"overview"}}
        paperCache=({})
        paperTabs=tabs
        var active=Number.isInteger(entry.active)?entry.active:-1
        if(active>=0 && active<tabs.length){searchView={selected:selected,detailTab:detailTab};enterPaper(active)}
    }
    FileView {
        id:tabsFile
        path:root.stateDir+"/tabs.json"
        atomicWrites:true
        onLoaded:root.restoreTabs(text())
        onLoadFailed:error=>root.restoreTabs("")
    }
    // Opens a clip (rect_pt) or page note from a reader tab in the note editor.
    function editClip(clip) {
        if(!selected || !inPdfTab || selected.id!==activePaper.id)return
        composeInSide(null,clip)
    }
    function composeInSide(note, clip) {
        closeMenus()
        composerError=""
        composer={note:note||null,clip:clip||null,token:"ui-"+Date.now()+"-"+Math.random().toString(36).slice(2),
            projectId:note?note.project_id:(projectId||null),labels:note?(note.labels||[]).join(", "):"",
            evidence:note?(note.evidence||""):clip?"PDF p. "+clip.page:""}
        detailTab="notes"
    }
    function cancelComposer() {
        composer=null
        composerError=""
        Qt.callLater(focusActiveTab)
    }
    function saveComposer(body, noteProjectId, labelText, evidenceText) {
        var draft=composer
        if(!draft || composerSaving || !selected)return
        var clip=draft.note ? null : draft.clip
        if(!body.trim() && !(clip && clip.rect_pt) && !(draft.note && draft.note.image)){composerError="Write something first";return}
        var method=draft.note ? "update_note" : clip && clip.rect_pt ? "add_visual_note" : "add_note"
        var args={ref_id:selected.id,project_id:noteProjectId,body:body,provenance:"human",evidence:evidenceText,idempotency_key:draft.token,
            labels:labelText.split(",").map(function(s){return s.trim()}).filter(function(s){return s.length>0})}
        if(clip && clip.rect_pt){args.source_pdf=clip.source_pdf;args.page=clip.page;args.rect_pt=clip.rect_pt}
        if(draft.note){args.id=draft.note.id;args.expected_revision=draft.note.revision}
        composerSaving=true
        composerError=""
        var id=rpc(method,args,function(){
            root.composerSaving=false
            if(root.composer!==draft)return
            root.composer=null
            root.flash("Saved")
            root.reloadDetail()
            Qt.callLater(root.focusActiveTab)
        },function(message){root.composerSaving=false;root.composerError=message})
        if(id<0)composerSaving=false
    }
    onActiveTabChanged: if(composer)composer=null
    function fileUrl(path) { return "file://" + path.split("/").map(encodeURIComponent).join("/") }
    function openExternal(url) {
        if(/^https?:\/\//i.test(url)) {
            Quickshell.execDetached(["omarchy-launch-browser", url])
        } else {
            Qt.callLater(function() { if(!Qt.openUrlExternally(url)) error="Could not open "+url })
        }
    }
    // Enter on a result: its PDF in a reader tab, or its link when there is no PDF.
    function openPdf() {
        var hit=targetRef();if(!hit)return
        rpc("open_target",{id:hit.id},function(r){ if(r.kind==="pdf")openPdfTab(hit,false); else openExternal(r.url) })
    }
    function openLink() {
        var hit=targetRef();if(!hit)return
        rpc("open_target",{id:hit.id,prefer:"link"},function(r){openExternal(r.url)})
    }
    function openPdfExternally() {
        var hit=targetRef();if(!hit)return
        rpc("get_pdf",{ref_id:hit.id,download:false},function(r){Quickshell.execDetached(["xdg-open",r.path])})
    }
    function arxivIdOf(ref) { return Format.arxivId(ref) }
    function openCodex(desktop) {
        var hit=targetRef()
        if(!hit || codexBusy)return
        codexBusy=true;error=""
        var launcher=desktop ? (settings.ai_desktop==="claude" ? ["omabib-claude","--desktop"] : ["omabib-chatgpt"])
                             : (settings.ai_cli==="claude" ? ["omabib-claude"] : ["omabib-codex"])
        codexProcess.command=launcher.concat([serviceSocket,hit.id,projectId||""])
        codexProcess.running=true
    }
    Process {
        id:codexProcess
        stdout:SplitParser {onRead:data=>{
            try {
                var r=JSON.parse(data)
                if(r.error)root.error=r.error
                else if(r.opened)root.dismiss()
            } catch(e){root.error="Could not launch chat: "+e}
        }}
        onExited:(exitCode,exitStatus)=>{root.codexBusy=false;if(exitCode!==0&&!root.error)root.error="Could not launch chat. Check that the selected application is installed."}
    }
    function openAlphaXiv() {
        var id=root.arxivIdOf(root.selected)
        if(!id){flash("Not recognized as an arXiv paper");return}
        openExternal(overviewRefId===selected.id && overviewUrl ? overviewUrl : "https://www.alphaxiv.org/abs/"+id)
    }
    // omabib-settings runs one command at a time; later requests wait their turn.
    function runSettings(args) {
        if(settingsProcess.running){settingsQueue=settingsQueue.concat([args]);return}
        settingsBusy=true
        settingsProcess.command=["omabib-settings"].concat(args)
        settingsProcess.running=true
    }
    function openSettings() {
        closeMenus()
        commandDialog.close()
        settingsDialog.open()
        runSettings([])
    }
    function setSetting(key, value) {
        var next=Object.assign({},settings); next[key]=value; settings=next
        runSettings(["set",key,value])
    }
    function registerClaudeDesktop() { runSettings(["register-claude-desktop",serviceSocket]) }
    Process {
        id:settingsProcess
        stdout:SplitParser {onRead:data=>{
            var r={}
            try{r=JSON.parse(data)}catch(e){r.error="Could not read settings"}
            if(r.error){
                root.error=r.error
                // A refused change leaves the optimistic value showing; reread.
                if(settingsProcess.command[1]==="set")root.settingsQueue=root.settingsQueue.concat([[]])
                return
            }
            root.settingsInfo=r
            root.settings=r.settings
        }}
        onExited:(code,status)=>{
            root.settingsBusy=false
            if(root.settingsQueue.length){var next=root.settingsQueue[0];root.settingsQueue=root.settingsQueue.slice(1);root.runSettings(next)}
        }
    }
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir","-p",stateDir])
        runSettings([])
    }
    function resetOverview() {
        overviewRefId="";overviewBody="";overviewUrl="";overviewState="idle";overviewMessage="";overviewFetchedAt="";overviewCached=false
    }
    // Loads the selected paper's alphaXiv overview for the AI summary tab.
    // Cached overviews come straight from SQLite; one helper process runs at
    // a time and picks up the latest selection when it finishes.
    function loadOverview(force) {
        var ref=selected
        if(!ref)return
        if(!arxivIdOf(ref)){overviewRefId=ref.id;overviewBody="";overviewState="unavailable";overviewMessage="Not recognized as an arXiv paper";return}
        if(!force && overviewRefId===ref.id && overviewState!=="idle" && overviewState!=="error")return
        var cached=overviewCache[ref.id]
        if(!force && cached){
            overviewRefId=ref.id;overviewBody=cached.body;overviewUrl=cached.url;overviewFetchedAt=cached.fetchedAt;overviewCached=true;overviewMessage=""
            overviewState="ready"
            return
        }
        overviewRefId=ref.id;overviewBody="";overviewUrl="";overviewMessage="";overviewFetchedAt="";overviewCached=false
        overviewState="loading"
        if(overviewProcess.running)return
        startOverview()
    }
    function startOverview() {
        overviewRequestId=overviewRefId
        overviewBusy=true
        overviewProcess.command=["omabib-overview",serviceSocket,overviewRequestId]
        overviewProcess.running=true
    }
    Process {
        id:overviewProcess
        stdout:SplitParser {onRead:data=>{
            var r={}
            try{r=JSON.parse(data)}catch(e){r.error="Invalid alphaXiv response"}
            if(root.overviewRequestId!==root.overviewRefId)return
            if(r.error){root.overviewState="error";root.overviewMessage=r.error;return}
            if(!r.available){root.overviewState="unavailable";root.overviewUrl=r.source_url||"";return}
            root.overviewBody=r.body
            root.overviewUrl=r.source_url
            root.overviewFetchedAt=r.fetched_at||""
            root.overviewCached=!!r.cached
            root.overviewState="ready"
            root.overviewCache[root.overviewRefId]={body:r.body,url:r.source_url,fetchedAt:r.fetched_at||""}
        }}
        onExited:(code,status)=>{
            root.overviewBusy=false
            if(root.overviewState!=="loading")return
            if(root.overviewRequestId!==root.overviewRefId)root.startOverview()
            else{root.overviewState="error";root.overviewMessage="The alphaXiv overview could not be loaded"}
        }
    }
    function selectTab(key) {
        if(detailTabs.indexOf(key)<0)return
        if(!inPaperTab && (!expanded || !selected)){var hit=currentHit();if(!hit)return;detailTab=key;showDetail();return}
        if(!selected){detailTab=key;return}
        if(key==="ai" && !arxivIdOf(selected)){flash("AI summaries are available for arXiv papers");return}
        detailTab=key
        if(key==="ai")loadOverview(false)
    }
    function cycleTab(delta) {
        if(!selected)return
        var keys=detailTabs.filter(function(k){return k!=="ai" || arxivIdOf(selected)})
        var i=keys.indexOf(detailTab)
        selectTab(keys[(i+delta+keys.length)%keys.length])
    }
    onDetailTabChanged: if(inPaperTab && activePaper.detail_tab!==detailTab) updateTab(activeTab,{detail_tab:detailTab})
    onSelectedChanged: {
        var id=selected?selected.id:""
        if(id!==lastSelectedId){
            lastSelectedId=id
            noteImages=({});noteImageRequests=({})
            if(detailTab==="ai" && selected && !arxivIdOf(selected))detailTab="overview"
        }
        if(selected && detailTab==="ai")loadOverview(false)
    }
    property bool pdfBusy: false
    property int pdfRequest: -1
    // Opens the PDF in a reader tab, first downloading an open-access copy if none is attached.
    function getPdf() {
        var hit=targetRef();if(!hit||pdfBusy)return
        if(inPdfTab && activePaper.id===hit.id)return
        pdfBusy=true
        pdfRequest=rpc("get_pdf",{ref_id:hit.id},function(r){
            pdfBusy=false
            openPdfTab(hit,false)
            if(r.source==="download")reloadDetail()
        })
        if(pdfRequest<0)pdfBusy=false
    }
    function copyPdfPath() {
        var hit=targetRef();if(!hit)return
        rpc("get_pdf",{ref_id:hit.id,download:false},function(r){copy(r.path)})
    }
    function pullPdf(attachmentId) {
        rpc("pull_pdf",{attachment_id:attachmentId},function(){flash("PDF restored");reloadDetail()})
    }
    function removePdfLink(attachmentId) {
        rpc("remove_pdf",{attachment_id:attachmentId},function(){flash("Attachment removed; file kept");reloadDetail()})
    }
    function lookupMetadata() {
        var hit=targetRef();if(!hit || metadataBusy)return
        metadataLookup=null;metadataChoice=null;metadataInfo="Looking up online metadata…";metadataDialog.open()
        metadataBusy=true
        metadataRequest=rpc("lookup_metadata",{id:hit.id},function(r){metadataLookup=r;metadataInfo=(r.warnings||[]).join("\n");if(!r.candidates.length)metadataInfo+="\nNo matching metadata found.";if(r.candidates.length===1)selectMetadata(0)})
        if(metadataRequest<0)metadataBusy=false
    }
    function selectMetadata(index) {
        metadataChoice=JSON.parse(JSON.stringify(metadataLookup.candidates[index]))
        metadataInfo="Existing values are preserved. Review the title, author and year before applying."
        if(metadataChoice.needs_abstract && metadataChoice.fields.doi){
            metadataBusy=true
            var choice=metadataChoice
            metadataRequest=rpc("supplement_metadata",{id:metadataLookup.id,doi:choice.fields.doi},function(r){
                if(metadataChoice!==choice)return
                var v=Object.assign({},choice)
                v.additions=Object.assign({},choice.additions,r.fields||{})
                if(Object.keys(r.fields||{}).length){v.source+="; "+r.source;v.gateway+=" + Europe PMC"}
                metadataChoice=v
                if(r.warning)metadataInfo+="\n"+r.warning
                else if(!r.fields.abstract)metadataInfo+="\nNo additional abstract available from Europe PMC."
            })
            if(metadataRequest<0)metadataBusy=false
        }
    }
    function metadataPreviewText() {
        var c=metadataChoice
        if(!c)return "Choose the correct matching paper to preview missing fields."
        var f=c.fields
        var out=(f.title||"Untitled")+"\n"+(f.author||"")+"\n"+(f.year||"")+(f.doi?" · "+f.doi:"")+"\n\nFound with "+c.gateway+"\n\nFields to fill\n"
        var keys=Object.keys(c.additions)
        if(!keys.length)out+="No missing fields available.\n"
        keys.sort(function(a,b){if(a==="abstract")return -1;if(b==="abstract")return 1;return a.localeCompare(b)})
        for(var i=0;i<keys.length;i++){var key=keys[i];out+="\n"+key.charAt(0).toUpperCase()+key.slice(1)+"\n"+c.additions[key]+"\n"}
        var conflicts=Object.keys(c.conflicts)
        if(conflicts.length)out+="\nExisting values kept: "+conflicts.join(", ")+".\n"
        return out+"\nSources\n"+c.source
    }
    function quickAddPreviewText(r) {
        var items=r.items||[]
        var out=""
        for(var i=0;i<items.length;++i){
            var it=items[i]
            if(i>0)out+="\n\n"
            out+=(it.title||it.citekey||it.input||"Entry "+(i+1))
            var line2=[]
            if(it.authors)line2.push(it.authors)
            if(it.year)line2.push(it.year)
            if(line2.length)out+="\n"+line2.join(" · ")
            if(it.recognized==="bibtex"){out+="\nPasted BibTeX"}
            else{
                out+="\n"+it.recognized+(it.abstract_source?" · abstract via "+it.abstract_source:" · no abstract found")+(it.pdf_url?" · open-access PDF found":"")
            }
        }
        if((r.warnings||[]).length)out+="\n\nNot recognized: "+r.warnings.join("; ")
        if(items.length===1 && items[0].recognized!=="bibtex")out+="\n\nImporting will also fetch and attach an open-access PDF, if one is found."
        return (out||("Recognized: "+r.recognized))+"\n\nBibTeX to import\n"+r.bibtex
    }
    // The single identifier being added, when the preview can show it as a
    // card rather than a text report.
    readonly property var previewItem: pendingImport && (pendingImport.items||[]).length===1 && pendingImport.items[0].recognized!=="bibtex" ? pendingImport.items[0] : null
    function applyMetadata() {
        if(!metadataChoice || metadataBusy)return
        metadataBusy=true
        metadataRequest=rpc("apply_metadata",{id:metadataLookup.id,expected_revision:metadataLookup.expected_revision,fields:metadataChoice.additions,source:metadataChoice.source},function(r){metadataDialog.close();refresh();flash("Filled "+r.filled.length+" metadata fields")})
    }
    function dismiss() {
        close()
        if (shell && shell.hide) shell.hide("omabib")
    }
    // Queue formulas ([{key, tex, display}]) that are not rendered or queued yet.
    function ensureMath(items) {
        var added=false
        for(var i=0;i<(items||[]).length;++i){var m=items[i];if(mathCache[m.key]||mathQueued[m.key])continue;mathQueued[m.key]=true;mathQueue.push(m);added=true}
        if(added)mathTimer.restart()
    }
    function flushMath() {
        if(!mathQueue.length||!socket.connected)return
        var batch=mathQueue.splice(0,200),color=mathColor
        var id=rpc("render_math",{items:batch.map(function(m){return {tex:m.tex,display:m.display}}),color:color,size_px:ui.title},function(r){
            if(color!==root.mathColor)return
            var next=Object.assign({},root.mathCache)
            for(var i=0;i<batch.length;++i){next[batch[i].key]=r.items[i]||{error:""};delete root.mathQueued[batch[i].key]}
            root.mathCache=next
        })
        if(id>=0)mathRequests[id]=batch
        if(mathQueue.length)mathTimer.restart()
    }
    // A failed request leaves its formulas as TeX source instead of an error banner.
    function mathFailed(id, message) {
        var batch=mathRequests[id]||[]
        delete mathRequests[id]
        var next=Object.assign({},mathCache)
        for(var i=0;i<batch.length;++i){next[batch[i].key]={error:message};delete mathQueued[batch[i].key]}
        mathCache=next
    }
    function rpc(method, params, callback, onError) {
        if (!socket.connected) { error = "Omabib service is unavailable. Start it with systemctl --user start omabib."; return -1 }
        var id = ++sequence
        if(method==="search"){if(pendingSearch!==-1)delete pending[pendingSearch];pendingSearch=id}
        pending[id] = callback || function() {}
        if(onError)rpcErrors[id]=onError
        socket.write(JSON.stringify({v:1,id:id,method:method,params:params}) + "\n")
        socket.flush()
        return id
    }
    function refresh() {
        rpc("get_repo_config",{},function(r){repoSettings=r})
        rpc("repo_status",{},function(r){repoStatus=r})
        rpc("list_projects", {}, function(r) { projects = r.projects; updateProjectName() })
        rpc("status", {}, function(r) { referenceCount = r.references })
        search(false)
        if(inPaperTab) loadPaper(activeTab)
    }
    function flash(text) {
        notice=text
        noticeTimer.restart()
    }
    function relativeTime(iso) { return Format.relativeTime(iso) }
    function syncChipText() {
        if(root.syncBusy)return "Syncing…"
        var s=root.repoStatus
        if(!s || s.configured!==true)return "Set up sync"
        if(s.last_error)return "Sync issue: "+s.last_error
        if(s.pending && s.pending.any)return "Changes pending sync"
        if(s.behind>0)return s.behind+" behind the remote"
        return "Synced "+root.relativeTime(s.last_success)
    }
    function updateProjectName() {
        projectName = "All references"
        for (var i=0; i<projects.length; ++i) if (projects[i].id===projectId) projectName = projects[i].name
    }
    function projectSelectIndex() {
        for(var i=0;i<projects.length;i++)if(projects[i].id===projectId)return i+1
        return 0
    }
    function toggleBrowseSort() {
        if(query.text.trim()!=="")return
        browseSort = browseSort==="added_desc" ? "citekey" : "added_desc"
        search(false)
        query.forceActiveFocus()
    }
    function setLibraryView(kind) {
        attentionView=""
        browseSort = kind==="recent" ? "added_desc" : "citekey"
        if(query.text!=="")query.text=""
        search(false)
        query.forceActiveFocus()
    }
    function setAttentionView(view) {
        attentionView=view||""
        search(false)
        query.forceActiveFocus()
    }
    function toggleSearchAllNotes() {
        allNotes=!allNotes
        search(false)
    }
    function queryEdited() {
        ++searchSequence
        searchPending=true
        lastInputAt=Date.now()
        debounce.restart()
    }
    function search(append) {
        debounce.stop()
        searchPending = true
        searchedAt = Date.now()
        var serial = ++searchSequence
        var priorId = currentHit() ? currentHit().id : ""
        var args = {query:query.text,limit:25,include_other_projects:allNotes}
        if(query.text.trim()==="")args.sort=browseSort
        if (projectId) { args.project_id = projectId; args.project_filter = projectId }
        if (append && nextCursor !== null) args.cursor = nextCursor
        if (authorFilter.text) args.author = authorFilter.text
        if (yearFilter.text) args.year = yearFilter.text
        if (typeFilter.text) args.entry_type = typeFilter.text
        if (labelFilter.text) args.label = labelFilter.text
        if (attentionView) args.view = attentionView
        rpc("search", args, function(r) {
            if (serial !== searchSequence) return
            searchPending = false
            hits = append ? hits.concat(r.results) : r.results
            nextCursor = r.next_cursor
            if (!append) {
                var requested=pendingOpenRefId
                var keep=hits.findIndex(function(h){return h.id===(requested||priorId)})
                results.currentIndex=keep>=0?keep:(hits.length?0:-1)
                if(hits.length)results.positionViewAtIndex(results.currentIndex,ListView.Contain)
                if(requested){pendingOpenRefId="";setSearchSelected(null);expanded=keep>=0}
                else if (expanded && keep<0) { setSearchSelected(null); expanded=false }
            }
            error = requested && keep<0 ? "The PDF reference could not be shown in this search." : ""
            responseMs = Date.now() - searchedAt
            paintStartedAt = lastInputAt || searchedAt
            paintPending = true
            candidatesLimited = r.candidate_limited || false
            if (expanded && hits.length) showDetail()
        })
    }
    function searchMore() { search(true) }
    function currentHit() { return hits.length ? hits[results.currentIndex >= 0 && results.currentIndex < hits.length ? results.currentIndex : 0] : null }
    function navigate(delta) {
        if (!hits.length) return
        results.currentIndex = Math.max(0, Math.min(hits.length-1, results.currentIndex+delta))
        results.positionViewAtIndex(results.currentIndex, ListView.Contain)
        if (expanded) showDetail()
    }
    function selectHit(index) {
        if(index<0 || index>=hits.length)return
        results.currentIndex=index
        showDetail()
        query.forceActiveFocus()
    }
    function showDetail() {
        var hit = currentHit()
        if (!hit) return
        expanded = true
        var requestedId = hit.id
        var requestedProjectId = projectId
        rpc("get_reference", {id:hit.id,project_id:projectId||null,include_notes:true,include_attachments:true,include_other_projects:includeOtherNotes,note_chars:65536}, function(r) {
            if (projectId===requestedProjectId && currentHit() && currentHit().id===requestedId) setSearchSelected(r)
        })
    }
    function collapseDetail() {
        expanded=false
        query.forceActiveFocus()
    }
    function toggleOtherNotes() {
        includeOtherNotes=!includeOtherNotes
        reloadDetail()
    }
    function reloadDetail() {
        if(inPaperTab) loadPaper(activeTab)
        else showDetail()
    }
    function loadMoreNotes() {
        if(!selected || selected.next_note_cursor===null || selected.next_note_cursor===undefined)return
        var refId=selected.id
        rpc("get_reference",{id:refId,project_id:projectId||null,include_notes:true,include_other_projects:includeOtherNotes,note_cursor:selected.next_note_cursor,note_chars:65536},function(r){
            if(!selected || selected.id!==refId)return
            var v=Object.assign({},selected);v.notes=v.notes.concat(r.notes);v.next_note_cursor=r.next_note_cursor;selected=v
        })
    }
    function loadNoteImage(note) {
        if(!note || !note.image || noteImages[note.id] || noteImageRequests[note.id])return
        noteImageRequests[note.id]=true
        var refId=selected?selected.id:""
        rpc("get_note_image",{note_id:note.id,project_id:note.project_id},function(r){
            if(!selected || selected.id!==refId)return
            var images=Object.assign({},noteImages)
            images[note.id]="data:image/png;base64,"+r.data
            noteImages=images
        })
    }
    function copy(text) {
        Quickshell.clipboardText = text
        flash("Copied")
    }
    function copyKey() { var hit=targetRef(); if (hit) { copy(hit.citekey); dismiss() } }
    function copyFormat(format) {
        var hit=targetRef();if(!hit)return
        if(format==="key")copy(hit.citekey)
        else if(format==="latex")copy("\\cite{"+hit.citekey+"}")
        else if(format==="pandoc")copy("[@"+hit.citekey+"]")
        else rpc("export_bibtex",{ids:[hit.id]},function(r){copy(r.bibtex)})
    }
    // A light heuristic for "this looks addable", used only to steer the
    // empty-results hint and Enter's behavior; the server does the real
    // recognition (and accepts several of these pasted together).
    function looksLikeIdentifier(text) {
        text=(text||"").trim()
        if(!text)return false
        if(/^(doi:)?10\.\S+\/\S+/i.test(text))return true
        if(/doi\.org\//i.test(text))return true
        if(/^arxiv:/i.test(text))return true
        if(/arxiv\.org\//i.test(text))return true
        if(/^\d{4}\.\d{4,5}(v\d+)?$/.test(text))return true
        if(/^[a-z-]+\/\d{7}$/i.test(text))return true
        if(/^https?:\/\//i.test(text))return true
        return false
    }
    function startQuickAdd(text) {
        edit("quick")
        editor.text=text
    }
    function edit(kind, n) {
        // In a reader tab notes are written in the side pane, beside the page.
        if(kind==="note" && inPdfTab && selected && selected.id===activePaper.id){composeInSide(n,null);return}
        closeMenus()
        editToken = "ui-"+Date.now()+"-"+Math.random().toString(36).slice(2)
        editKind = kind
        editingNote = n || null
        if(kind==="note") { noteTargetId=selected?selected.id:""; noteTargetTitle=selected?selected.title:"" }
        editorDialog.title = kind==="note" ? (n ? "Edit note" : "New note") : kind==="metadata" ? "Edit BibTeX" : kind==="import" ? "Import BibTeX" : kind==="quick" ? "Add to library" : kind==="doi" ? "Add DOI" : kind==="project" ? "Create project" : "Link existing file"
        if(kind==="note") noteEditor.text = n ? n.body : ""
        else editor.text = kind==="metadata" && selected ? selected.bibtex : kind==="import" ? "@article{key,\n  title = {},\n  author = {},\n  year = {}\n}" : ""
        labels.text = n ? (n.labels || []).join(", ") : ""
        evidence.text = n ? (n.evidence || "") : ""
        noteScope.currentIndex = 0
        var pid = n ? n.project_id : projectId
        for(var i=0;i<projects.length;++i) if(projects[i].id===pid)noteScope.currentIndex=i+1
        editorDialog.open()
        Qt.callLater(function(){activeEditor().forceActiveFocus()})
    }
    // Notes get the Markdown editor; every other kind edits plain text.
    function activeEditor() { return editKind==="note" ? noteEditor : editor }
    function saveEditor() {
        var body=activeEditor().text
        if ((!body.trim() && !(editingNote && editingNote.image)) || noteSaving) return
        var method, args
        if (editKind==="note") {
            if (!noteTargetId) return
            method = editingNote ? "update_note" : "add_note"
            args={ref_id:noteTargetId,project_id:noteScope.currentIndex===0 ? null : projects[noteScope.currentIndex-1].id,body:body,provenance:"human",labels:labels.text.split(",").map(function(s){return s.trim()}).filter(function(s){return s.length>0}),evidence:evidence.text}
            if(editingNote){args.id=editingNote.id;args.expected_revision=editingNote.revision}
        } else if(editKind==="metadata") {
            method="upsert_reference";args={id:selected.id,expected_revision:selected.revision,bibtex:body}
        } else if(editKind==="import") {method="import_bibtex";args={bibtex:body,source:"Omabib UI"}}
        else if(editKind==="quick") {
            noteSaving=true
            noteSaveRequest=rpc("preview_entry",{input:body},function(r){noteSaving=false;pendingImport=r;previewShowBibtex=false;previewBody.text=root.quickAddPreviewText(r);editorDialog.close();previewDialog.open()})
            if(noteSaveRequest<0)noteSaving=false
            return
        }
        else if(editKind==="doi") {
            rpc("preview_doi",{doi:body.trim()},function(r){pendingImport=r;previewShowBibtex=false;previewBody.text=r.bibtex+(r.conflicts&&r.conflicts.length?"\n\nExisting values will be preserved. Conflicts:\n"+JSON.stringify(r.conflicts,null,2):"");editorDialog.close();previewDialog.open()});return
        } else if(editKind==="project") {method="create_project";args={name:body.trim()}}
        else {if(!selected)return;method="attach";args={ref_id:selected.id,path:body.trim(),file_type:"pdf"}}
        args.idempotency_key=editToken
        noteSaving=editKind==="note"
        var submittedToken=editToken
        noteSaveRequest=rpc(method,args,function(r){if(editToken!==submittedToken)return;editorDialog.close();flash("Saved");refresh();if(!inPaperTab && expanded)showDetail();showImportReport(r)})
        if(noteSaveRequest<0)noteSaving=false
    }
    function showImportReport(r) {
        if(r.duplicates_merged || (r.repairs||[]).length) {
            flash("Imported "+(r.items||[]).length+" unique references · merged "+(r.duplicates_merged||0)+" duplicates · "+(r.repairs||[]).length+" repairs")
        }
        var renamed=(r.items||[]).filter(function(i){return i.original_key && i.original_key!==i.citekey})
        if ((r.conflicts||[]).length || renamed.length) {
            pendingImport=null
            previewBody.text="Existing values were preserved. Resolve field conflicts with Edit BibTeX.\n\n"+JSON.stringify({conflicts:r.conflicts||[],repairs:r.repairs||[],duplicates_merged:r.duplicates_merged||0,renamed_keys:renamed.map(function(i){return {original:i.original_key,assigned:i.citekey}})},null,2)
            previewDialog.open()
        }
    }
    function editPreviewBibtex() {
        if(!pendingImport)return
        var bib=pendingImport.bibtex
        previewDialog.close()
        edit("import")
        editor.text=bib
    }
    function syncHistory() {
        if(syncBusy)return
        if(!repoSettings.configured){openRepoSettings();return}
        syncBusy=true
        syncRequest=rpc("sync_repo",{push:true},function(r){
            syncBusy=false
            flash(r.ok===false?("Saved locally, but the push failed: "+(r.push_error||"")):"History synced · "+r.references+" references")
            rpc("repo_status",{},function(s){repoStatus=s})
        })
        if(syncRequest===-1)syncBusy=false
    }
    function openRepoSettings() {
        rpc("get_repo_config",{},function(r){repoSettings=r;repoPath.text=r.repo_path||"";repoRemote.text=r.remote_url||"";repoBranch.text=r.branch||"main";repoDialog.open();root.checkRepoPrereqs()})
    }
    function checkRepoPrereqs() {
        var args={}
        if(repoPath.text)args.repo_path=repoPath.text
        rpc("repo_check",args,function(r){root.repoCheck=r})
    }
    // [label, ok, detail] rows for the repository dialog's checklist.
    function repoChecks() {
        var c=root.repoCheck
        if(c===undefined||c.git===undefined)return []
        var rows=[["git",!!c.git,c.git?"":"missing"],["git-lfs",!!c.git_lfs,c.git_lfs?"":"missing"],["gh",!!c.gh_logged_in,c.gh_logged_in?(c.gh_user||"logged in"):(c.gh?"run gh auth login":"missing")]]
        if(c.path&&c.path.state==="repo")rows.push(["path",true,"existing repo"+(c.path.lfs_tracked?", LFS tracked":", LFS not tracked yet")+(c.path.dirty?", has local edits":"")])
        else if(c.path&&c.path.state&&c.path.state!=="unspecified")rows.push(["path",c.path.state==="empty"||c.path.state==="missing",c.path.state.replace(/_/g," ")])
        return rows
    }
    function repoCheckSummary() {
        var rows=repoChecks()
        if(!rows.length)return "Checking…"
        return rows.map(function(r){return r[0]+(r[1]?" ✓":" ✗")+(r[2]?" "+r[2]:"")}).join("   ·   ")
    }
    function createGithubRepo() {
        if(!repoNewName.text.trim()){root.error="Name the new repository first";return}
        var args={mode:"create_github",name:repoNewName.text.trim(),branch:repoBranch.text||"main"}
        if(repoPath.text)args.repo_path=repoPath.text
        root.repoBusy=true
        root.rpc("repo_setup",args,function(r){root.repoBusy=false;root.repoSettings=r;repoDialog.close();root.flash("Created and configured "+repoNewName.text.trim());root.checkRepoPrereqs()})
    }
    function useLocalRepo() {
        root.repoBusy=true
        root.rpc("repo_setup",{mode:"local",repo_path:repoPath.text,remote_url:repoRemote.text,branch:repoBranch.text||"main",fix_lfs:true},function(r){root.repoBusy=false;root.repoSettings=r;repoDialog.close();root.flash("Repository settings saved")})
    }
    function choosePdf() {
        var hit=targetRef();if(!hit)return
        attachmentRefId=hit.id;pickerKind="pdf";bibFileDialog.open()
    }
    function acceptFile(url) {
        if(pickerKind!=="pdf"){importBibFile(url);return}
        rpc("add_pdf",{ref_id:attachmentRefId,path:decodeURIComponent(url.slice(7))},function(r){flash("PDF attached");reloadDetail()})
    }
    readonly property int actionCount: 26
    function actionDigit(digit) {
        actionTimer.stop()
        var number=Number(actionDigits+digit)
        if (actionDigits==="" && Number(digit)*10<=root.actionCount) {actionDigits=digit;actionTimer.restart();return}
        actionDigits=""
        if(number>=1 && number<=root.actionCount)runAction(number)
    }
    function clearActionDigits() {
        actionDigits=""
        actionTimer.stop()
    }
    function openCommands() {
        closeMenus()
        commandDialog.open()
    }
    function runAction(number) {
        actionTimer.stop()
        actionDigits=""
        commandDialog.close()
        switch(number) {
        case 1:edit("quick");break
        case 2:copyKey();break
        case 3:copyFormat("latex");break
        case 4:copyFormat("pandoc");break
        case 5:copyFormat("bibtex");break
        case 6:edit("import");break
        case 7:pickerKind="bib";bibFileDialog.open();break
        case 8:edit("doi");break
        case 9:detailThenEdit("note");break
        case 10:choosePdf();break
        case 11:openLink();break
        case 12:getPdf();break
        case 13:copyPdfPath();break
        case 14:lookupMetadata();break
        case 15:assign();break
        case 16:edit("project");break
        case 17:if(projectId)rpc("export_bibtex",{project_id:projectId},function(r){copy(r.bibtex)});else flash("Choose a project first");break
        case 18:if(projectId)rpc("export_notes",{project_id:projectId},function(r){copy(r.markdown)});else flash("Choose a project first");break
        case 19:syncHistory();break
        case 20:openRepoSettings();break
        case 21:requestDelete();break
        case 22:openCodex();break
        case 23:openCodex(true);break
        case 24:openSettings();break
        case 25:openInTab(null,false);break
        case 26:closeActiveTab();break
        }
    }
    // After adding, replace whatever search/display was up with the newly
    // added reference itself, expanded — it's what the user just asked for.
    function focusOnReference(citekey) {
        if(!citekey)return
        activateTab(-1)
        expanded=true
        detailTab="overview"
        attentionView=""
        authorFilter.text="";yearFilter.text="";typeFilter.text="";labelFilter.text=""
        query.text=citekey
        query.forceActiveFocus();query.selectAll()
    }
    function importPreview() {
        if(!pendingImport || noteSaving)return
        var items=pendingImport.items||[]
        if(items.length===1 && items[0].recognized!=="bibtex") {
            var item=items[0]
            noteSaving=true
            noteSaveRequest=rpc("add_reference",{input:item.input,download_pdf:true,project_id:projectId||null,idempotency_key:editToken+"-add"},function(r){
                noteSaving=false
                previewDialog.close();refresh()
                root.focusOnReference(r.citekey)
                flash("Added "+r.citekey+(r.merged?" (filled an existing reference)":"")+(r.attachment&&r.attachment.exists?" · PDF attached":"")+(r.abstract_source?" · abstract via "+r.abstract_source:""))
            })
            if(noteSaveRequest<0)noteSaving=false
            return
        }
        rpc("import_bibtex",pendingImport,function(r){
            previewDialog.close();refresh()
            var first=(r.items||[])[0]
            if(first)root.focusOnReference(first.citekey)
            flash("Imported");showImportReport(r)
        })
    }
    function importBibFile(url) {
        if (!url.startsWith("file://")) {error="Choose a local BibTeX file";return}
        importPath=decodeURIComponent(url.slice(7))
        importingFile=true
        if(bibFile.path===importPath)bibFile.reload()
        else bibFile.path=importPath
    }
    Timer {id:actionTimer;interval:700;onTriggered:root.runAction(Number(root.actionDigits))}
    FileView {
        id:bibFile
        onLoaded:{
            if(!root.importingFile)return
            root.importingFile=false
            root.rpc("import_bibtex",{bibtex:text(),source:root.importPath,idempotency_key:"file-"+Date.now()+"-"+Math.random().toString(36).slice(2)},function(r){root.flash("Imported "+r.items.length+" references");root.refresh();root.showImportReport(r)})
        }
        onLoadFailed:error=>{root.importingFile=false;root.error="Could not read BibTeX file: "+root.importPath}
    }
    function chooseProject(index) {
        if(index<0 || index>projects.length)return
        projectId = index===0 ? "" : projects[index-1].id
        updateProjectName(); search(false)
        Qt.callLater(function(){query.forceActiveFocus()})
    }
    function openProjectMenu(anchor) {
        var items=[{key:"",label:"All references",icon:"library",selected:projectId===""}]
        if(projects.length)items.push({section:"Projects"})
        for(var i=0;i<projects.length;i++)items.push({key:projects[i].id,label:projects[i].name,icon:"folder",selected:projects[i].id===projectId})
        items.push({separator:true})
        items.push({key:"__create",label:"Create project…",icon:"plus"})
        projectMenu.items=items
        projectMenu.openAt(anchor||tabStrip.projectAnchor, anchor&&anchor!==tabStrip.projectAnchor?"side":"left")
    }
    function openAttentionMenu(anchor) {
        attentionMenu.items=[
            {section:"Needs attention"},
            {key:"missing_abstract",label:"Missing abstract",icon:"text",selected:attentionView==="missing_abstract"},
            {key:"missing_pdf",label:"Missing PDF",icon:"fileMissing",selected:attentionView==="missing_pdf"},
            {separator:true},
            {key:"",label:"Show everything",icon:"library",selected:attentionView===""}
        ]
        attentionMenu.openAt(anchor,"side")
    }
    function openOverflowMenu(anchor) {
        if(!selected)return
        overflowMenu.items=[
            {key:"metadata",label:"Fill metadata…",icon:"refresh"},
            {key:"bibtex",label:"Edit BibTeX…",icon:"pencil"},
            {key:"assign",label:"Assign to project…",icon:"folder"},
            {key:"attach",label:"Attach PDF…",icon:"pdf"},
            {section:"Copy"},
            {key:"copy_key",label:"Citation key",icon:"copy"},
            {key:"copy_latex",label:"LaTeX citation",icon:"copy"},
            {key:"copy_pandoc",label:"Pandoc / Quarto citation",icon:"copy"},
            {key:"copy_bibtex",label:"BibTeX",icon:"braces"},
            {key:"copy_pdf",label:"PDF path",icon:"pdf"},
            {separator:true},
            {key:"external_pdf",label:"Open PDF in another app",icon:"external"},
            {separator:true},
            {key:"delete",label:"Delete…",icon:"trash",danger:true}
        ]
        overflowMenu.openAt(anchor,"right")
    }
    function detailThenEdit(kind) {
        if(inPaperTab){if(selected)edit(kind,null);return}
        var hit=currentHit();if(!hit)return
        rpc("get_reference",{id:hit.id,project_id:projectId||null,include_notes:true,include_attachments:true},function(r){selected=r;expanded=true;edit(kind,null)})
    }
    function assign() {
        var hit=targetRef()
        if(!hit || !projects.length)return
        closeMenus()
        assignTargetId=hit.id
        projectDialog.open()
    }
    function requestDelete() {
        var hit=targetRef()
        if(!hit || deleteBusy)return
        var id=hit.id
        error=""
        rpc("delete_reference_preview",{id:id},function(r){
            if(!targetRef() || targetRef().id!==id)return
            deletePreview=r
            deleteDialog.open()
        })
    }
    function confirmDelete() {
        if(!deletePreview || deleteBusy)return
        var target=deletePreview
        deleteBusy=true
        error=""
        deleteRequest=rpc("delete_reference",{id:target.id,expected_revision:target.revision,confirm_citekey:target.citekey,expected_notes:target.note_count,expected_attachments:target.attachment_count,idempotency_key:"ui-delete-"+Date.now()+"-"+Math.random().toString(36).slice(2)},function(r){
            deleteBusy=false;deleteRequest=-1;deleteDialog.close()
            if(overviewRefId===target.id)resetOverview()
            delete overviewCache[target.id]
            var fromTab=inPaperTab && activePaper.id===target.id
            for(var i=paperTabs.length-1;i>=0;--i)if(paperTabs[i].id===target.id)closeTab(i)
            if(!fromTab){setSearchSelected(null);expanded=false}
            if(query.text.trim()===target.citekey)query.text=""
            flash("Deleted "+r.citekey+" · PDF files kept")
            refresh();query.forceActiveFocus()
        })
        if(deleteRequest<0)deleteBusy=false
    }
    function requestNoteDelete(id) {
        if(!selected || noteDeleteBusy)return
        var refId=selected.id
        error=""
        rpc("delete_note_preview",{id:id},function(r){
            if(!selected || selected.id!==refId || r.ref_id!==refId)return
            noteDeletePreview=r
            noteDeleteDialog.open()
        })
    }
    function confirmNoteDelete() {
        if(!noteDeletePreview || noteDeleteBusy)return
        var target=noteDeletePreview
        noteDeleteBusy=true
        error=""
        noteDeleteRequest=rpc("delete_note",{id:target.id,expected_revision:target.revision,confirm_ref_id:target.ref_id,idempotency_key:"ui-delete-note-"+Date.now()+"-"+Math.random().toString(36).slice(2)},function(){
            noteDeleteBusy=false;noteDeleteRequest=-1;noteDeleteDialog.close()
            flash("Note deleted")
            refresh();if(!inPaperTab)showDetail()
        })
        if(noteDeleteRequest<0)noteDeleteBusy=false
    }
    function assignToProject(index) {
        if(index<0 || index>=projects.length || !assignTargetId)return
        var refId=assignTargetId, target=projects[index]
        assignTargetId=""
        projectDialog.close()
        rpc("associate",{ref_id:refId,project_id:target.id,labels:[],idempotency_key:"ui-associate-"+Date.now()+"-"+Math.random().toString(36).slice(2)},function(){flash("Assigned to "+target.name);search(false)})
    }
    IpcHandler {
        target: "omabib"
        function setQuery(text: string): void { query.text = text }
        function selectProject(index: int): void { root.chooseProject(index) }
        function selectTab(name: string): void { root.selectTab(name) }
        function openAssign(): void { root.assign() }
        function openCodex(): void { root.openCodex() }
        function openSettings(): void { root.openSettings() }
        function openTab(): void { root.openInTab(null, false) }
        function openPdf(refId: string): void { root.open(JSON.stringify({action: "pdf", ref_id: refId})) }
        function activateTab(index: int): void { root.activateTab(index) }
        function closeTab(index: int): void { root.closeTab(index) }
        function openChatGPT(): void { root.openCodex(true) }
        function openDelete(): void { root.requestDelete() }
        function openNoteDelete(id: string): void { root.requestNoteDelete(id) }
        function loadOverview(): void { root.selectTab("ai") }
        function state(): string { return JSON.stringify({opened:root.opened,window_focused:window.active,composer:root.composer?{kind:root.composer.note?"edit":root.composer.clip&&root.composer.clip.rect_pt?"clip":"note",page:root.composer.clip?root.composer.clip.page:null,saving:root.composerSaving,error:root.composerError}:null,note_target_id:root.noteTargetId,note_evidence:evidence.text,note_scope:noteScope.currentIndex,editor_focused:root.activeEditor().activeFocus,expanded:root.expanded,query:query.text,project_id:root.projectId,project_name:root.projectName,project_select_index:root.projectSelectIndex(),assign_open:projectDialog.opened,delete_open:deleteDialog.opened,delete_preview:root.deletePreview?root.deletePreview.citekey:null,note_delete_open:noteDeleteDialog.opened,note_delete_preview:root.noteDeletePreview?root.noteDeletePreview.id:null,assign_enabled:root.selected!==null&&root.projects.length>0,detail_tab:root.detailTab,tabs:root.paperTabs.map(function(t){return t.citekey}),tab_kinds:root.paperTabs.map(function(t){return t.kind||"paper"}),active_tab:root.activeTab,pdf:root.inPdfTab?{status:readerPane.status,page:readerPane.currentPage,pages:readerPane.doc?readerPane.doc.page_count:0,zoom:readerPane.zoom,zoom_mode:readerPane.zoomMode,tool:readerPane.tool,rendered:Object.keys(readerPane.renders).length,clips:readerPane.clips.length,message:readerPane.message}:null,tabs_restored:root.tabsRestored,settings_open:settingsDialog.opened,ai_cli:root.settings.ai_cli,ai_desktop:root.settings.ai_desktop,attention_view:root.attentionView,overflow_open:overflowMenu.opened,project_menu_open:projectMenu.opened,overview_visible:root.detailTab==="ai"&&root.overviewState==="ready"&&!!root.selected&&root.overviewRefId===root.selected.id,overview_state:root.overviewState,overview_busy:root.overviewBusy,overview_ref_id:root.overviewRefId,overview_chars:root.overviewBody.length,browse_sort:root.browseSort,results:root.hits.map(function(h){return h.citekey}),result_index:results.currentIndex,selected:root.selected?root.selected.id:null,error:root.error,notice:root.notice,editor_open:editorDialog.opened,commands_open:commandDialog.opened,file_picker_open:bibFileDialog.visible,action_digits:root.actionDigits,repo_open:repoDialog.opened,metadata_open:metadataDialog.opened,import_preview_open:previewDialog.opened,metadata_busy:root.metadataBusy,metadata_candidates:root.metadataLookup?root.metadataLookup.candidates.length:0,pdf_busy:root.pdfBusy,sync_busy:root.syncBusy,picker_kind:root.pickerKind,picker_path:filePath.text,picker_matches:bibFileDialog.matches.map(function(m){return m.name}),picker_index:fileList.currentIndex,picker_focused:filePath.activeFocus,picker_chosen:bibFileDialog.lastChosen,edit_kind:root.editKind,query_focused:query.activeFocus,response_ms:root.responseMs,paint_ms:root.lastPaintMs,open_ms:root.openMs,search_pending:root.searchPending,paint_pending:root.paintPending,open_pending:root.openPending}) }
    }
    Timer { id: noticeTimer; interval: 2500; onTriggered: root.notice="" }
    Timer { id: debounce; interval: 12; onTriggered: root.search(false) }
    Timer { interval: 1500; running: !socket.connected; repeat: true; onTriggered: socket.connected=true }
    Timer { id: mathTimer; interval: 60; onTriggered: root.flushMath() }
    Socket {
        id: socket
        path: root.serviceSocket
        connected: true
        onConnectedChanged: {
            if(connected){root.error="";root.connectionEpoch++;Qt.callLater(root.flushMath);if(root.opened)root.refresh()}
            else {for(var id in root.mathRequests)root.mathQueue=root.mathQueue.concat(root.mathRequests[id]);root.mathRequests=({});root.pending=({});root.rpcErrors=({});root.noteSaving=false;root.metadataBusy=false;root.syncBusy=false;root.pdfBusy=false;root.error="Library service disconnected. Reconnecting…"}
        }
        parser: SplitParser {
            onRead: data => {
                try {
                    var message=JSON.parse(data)
                    var callback=root.pending[message.id]
                    delete root.pending[message.id]
                    if(message.id===root.syncRequest)root.syncBusy=false
                    if(message.id===root.metadataRequest)root.metadataBusy=false
                    if(message.id===root.pdfRequest)root.pdfBusy=false
                    if(message.id===root.noteSaveRequest)root.noteSaving=false
                    if(message.id===root.deleteRequest){root.deleteBusy=false;root.deleteRequest=-1}
                    if(message.id===root.noteDeleteRequest){root.noteDeleteBusy=false;root.noteDeleteRequest=-1}
                    if(root.mathRequests[message.id]){if(message.error){root.mathFailed(message.id,message.error.message);return}delete root.mathRequests[message.id]}
                    var onError=root.rpcErrors[message.id]
                    delete root.rpcErrors[message.id]
                    if(message.error && onError){onError(message.error.message);return}
                    if(message.error){if(message.id===root.metadataRequest)root.metadataInfo=message.error.message;if(message.id===root.pendingSearch)root.searchPending=false;root.error=message.error.message;return}
                    if(callback)callback(message.result)
                } catch(e){root.error="Could not read the library response: "+e}
            }
        }
    }
    Connections {
        target: card.Window.window
        function onFrameSwapped() {
            if(root.paintPending){root.lastPaintMs=Date.now()-root.paintStartedAt;root.paintPending=false}
            if(root.openPending){root.openMs=Date.now()-root.openedAt;root.openPending=false}
        }
    }
    // A normal Hyprland window. `omabib open` (Super+B) shows, focuses or hides it.
    FloatingWindow {
        id: window
        title: "Omabib"
        visible: root.opened
        color: ui.app
        implicitWidth: 1320
        implicitHeight: 840
        minimumSize: Qt.size(760, 520)
        // Closed from Hyprland (Super+W, a close button): tell the shell, as dev-gallery does.
        onVisibleChanged: if(!visible && root.opened){root.close();if(root.shell && root.shell.hide)root.shell.hide("omabib")}
        Rectangle {
            id: card
            anchors.fill: parent
            readonly property bool wide: root.expanded || root.inPaperTab
            color: ui.app
            clip: true
            MouseArea { anchors.fill:parent;onClicked:root.inPaperTab?root.focusActiveTab():query.forceActiveFocus() }
            // Keyboard focus while a paper tab shows: typing starts a search in the library tab.
            Item {
                id: paperKeys
                Keys.onPressed: event => {
                    if(!root.inPaperTab || event.text==="" || (event.modifiers & (Qt.ControlModifier|Qt.AltModifier|Qt.MetaModifier)) || !/\S/.test(event.text))return
                    root.activateTab(-1)
                    query.text=event.text
                    query.cursorPosition=query.text.length
                    query.forceActiveFocus()
                    event.accepted=true
                }
            }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 1
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    Rail {
                        Layout.fillHeight: true
                        theme: ui
                        app: root
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 0
                        TabStrip {
                            id: tabStrip
                            Layout.fillWidth: true
                            theme: ui
                            app: root
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 0
                            ListPane {
                                id: listPane
                                visible: !root.inPaperTab
                                Layout.fillHeight: true
                                Layout.fillWidth: !root.expanded
                                Layout.preferredWidth: root.expanded ? Math.round(Math.max(ui.space(340), Math.min(ui.space(430), card.width * 0.32))) : -1
                                theme: ui
                                app: root
                            }
                            Rectangle { visible: root.expanded && !root.inPaperTab; Layout.fillHeight: true; implicitWidth: 1; color: ui.line }
                            ColumnLayout {
                                visible: card.wide
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 0
                                ErrorBanner { Layout.fillWidth: true }
                                DetailPane {
                                    visible: !root.inPdfTab
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    theme: ui
                                    app: root
                                }
                                ReaderPane {
                                    id: readerPane
                                    objectName: "readerPane"
                                    visible: root.inPdfTab
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    theme: ui
                                    app: root
                                    tab: root.inPdfTab ? root.activePaper : null
                                }
                            }
                        }
                    }
                }
                ErrorBanner { Layout.fillWidth: true; visible: !card.wide && root.error !== "" }
                StatusBar {
                    Layout.fillWidth: true
                    theme: ui
                    notice: root.notice
                    hints: root.inPdfTab
                        ? [["j/k", "scroll"], ["gg/G", "first/last"], ["/", "search"], ["r", "clip"], ["a", "page note"], ["o", "contents"], ["]", "notes"], ["^W", "close tab"]]
                        : root.inPaperTab
                        ? [[root.pdfShortcut.replace("Ctrl+", "^"), "PDF"], ["^U", "link"], ["^1–5", "sections"], ["^PgUp/Dn", "switch tab"], ["^W", "close tab"], ["type", "search"], ["q", "close"]]
                        : root.expanded
                        ? [["↑↓", "navigate"], ["↵", "open"], [root.pdfShortcut.replace("Ctrl+", "^"), "PDF"], ["^U", "link"], ["^T", "new tab"], ["^1–5", "sections"], ["^K", "actions"], ["q", "close"]]
                        : [["↑↓", "navigate"], ["↵", "open"], ["Tab", "details"], ["^T", "new tab"], ["^K", "actions"], ["q", "close"]]
                }
            }

            MenuPopup { id: projectMenu; theme: ui; menuWidth: ui.space(260); onTriggered: key => { if(key==="__create")root.edit("project");else root.chooseProject(root.projects.findIndex(function(p){return p.id===key})+1) } }
            MenuPopup { id: attentionMenu; theme: ui; onTriggered: key => root.setAttentionView(key) }
            MenuPopup {
                id: overflowMenu
                theme: ui
                menuWidth: ui.space(250)
                onTriggered: key => {
                    switch(key) {
                    case "metadata": root.lookupMetadata(); break
                    case "bibtex": root.edit("metadata", null); break
                    case "assign": root.assign(); break
                    case "attach": root.choosePdf(); break
                    case "copy_key": root.copyFormat("key"); break
                    case "copy_latex": root.copyFormat("latex"); break
                    case "copy_pandoc": root.copyFormat("pandoc"); break
                    case "copy_bibtex": root.copyFormat("bibtex"); break
                    case "copy_pdf": root.copyPdfPath(); break
                    case "external_pdf": root.openPdfExternally(); break
                    case "delete": root.requestDelete(); break
                    }
                }
            }
            CommandPalette { id: commandDialog; theme: ui; app: root }
        }
        Shortcut {sequence:root.pdfShortcut;enabled:root.opened&&!editorDialog.opened;onActivated:root.getPdf()}
        Shortcut {sequence:"Ctrl+U";enabled:root.opened&&!editorDialog.opened;onActivated:root.openLink()}
        Shortcut {sequence:"Ctrl+S";enabled:root.opened&&!root.modalOpen&&!root.inPaperTab;onActivated:root.toggleBrowseSort()}
        Shortcut {sequence:"Ctrl+T";enabled:root.opened&&!root.modalOpen&&!root.inPaperTab;onActivated:root.openInTab(null,false)}
        Shortcut {sequence:"Ctrl+W";enabled:root.opened&&!root.modalOpen&&root.inPaperTab;onActivated:root.closeActiveTab()}
        Shortcut {sequence:"Ctrl+F";enabled:root.opened&&!root.modalOpen;onActivated:{root.activateTab(-1);query.forceActiveFocus();query.selectAll()}}
        Shortcut {sequences:["Ctrl+PgDown"];enabled:root.opened&&!root.modalOpen;onActivated:root.cycleTopTab(1)}
        Shortcut {sequences:["Ctrl+PgUp"];enabled:root.opened&&!root.modalOpen;onActivated:root.cycleTopTab(-1)}
        Repeater {
            model: 10
            Item {
                required property int index
                // Alt+0 is the library tab; Alt+1–9 the paper tabs in order.
                Shortcut {sequence:"Alt+"+index;enabled:root.opened&&!root.modalOpen;onActivated:root.activateTab(index-1)}
            }
        }
        Shortcut {sequence:"Ctrl+K";enabled:root.opened&&!editorDialog.opened;onActivated:root.openCommands()}
        Shortcut {sequence:"Ctrl+P";enabled:root.opened&&!root.modalOpen;onActivated:root.openProjectMenu(null)}
        Shortcut {sequence:"Ctrl+1";enabled:root.opened&&!root.modalOpen;onActivated:root.selectTab("overview")}
        Shortcut {sequence:"Ctrl+2";enabled:root.opened&&!root.modalOpen;onActivated:root.selectTab("ai")}
        Shortcut {sequence:"Ctrl+3";enabled:root.opened&&!root.modalOpen;onActivated:root.selectTab("notes")}
        Shortcut {sequence:"Ctrl+4";enabled:root.opened&&!root.modalOpen;onActivated:root.selectTab("files")}
        Shortcut {sequence:"Ctrl+5";enabled:root.opened&&!root.modalOpen;onActivated:root.selectTab("bibtex")}
        Shortcut {sequences:["Ctrl+Tab"];enabled:root.opened&&card.wide&&!root.modalOpen;onActivated:root.cycleTab(1)}
        Shortcut {sequences:["Ctrl+Shift+Tab","Ctrl+Backtab"];enabled:root.opened&&card.wide&&!root.modalOpen;onActivated:root.cycleTab(-1)}
        // In a reader tab Esc first cancels the clip tool, a selection or a search.
        Shortcut {sequence:"Escape";enabled:root.opened&&!root.modalOpen&&!(root.inPdfTab&&readerPane.wantsEscape);onActivated:root.dismiss()}
        Shortcut {sequence:"Q";enabled:root.opened&&(root.inPaperTab||query.text.trim()==="")&&!root.modalOpen&&!(root.inPdfTab&&readerPane.searching);onActivated:root.dismiss()}
        BibDialog {
            id:settingsDialog;title:"Settings";iconName:"cog";anchors.centerIn:parent
            width:Math.min(640,window.width-60);height:Math.min(settingsScroll.contentHeight+ui.space(130),window.height-60);modal:true
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(10)
                ScrollView {
                    id:settingsScroll
                    Layout.fillWidth:true;Layout.fillHeight:true
                    contentWidth:availableWidth
                    SettingsPanel {width:settingsScroll.availableWidth;theme:ui;app:root}
                }
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(8)
                    BibButton{variant:"ghost";iconName:"branch";text:"History repository…";onClicked:{settingsDialog.close();root.openRepoSettings()}}
                    Item{Layout.fillWidth:true}
                    BibButton{variant:"primary";text:"Done";onClicked:settingsDialog.close()}
                }
            }
        }
        BibDialog {
            id:deleteDialog;title:"Delete reference";iconName:"trash";anchors.centerIn:parent;width:Math.min(500,window.width-60);modal:true;closePolicy:Popup.CloseOnEscape
            onClosed:{if(!root.deleteBusy)root.deletePreview=null}
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(12)
                Text {text:root.deletePreview ? root.deletePreview.title : "";color:ui.bright;font.family:ui.readingFamily;font.pixelSize:ui.heading;font.weight:Font.DemiBold;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                Chip {theme:ui;text:root.deletePreview ? root.deletePreview.citekey : "";bordered:true}
                BibLabel {text:root.deletePreview ? "This removes the reference with its "+root.deletePreview.note_count+" note(s), "+root.deletePreview.attachment_count+" attachment link(s), "+root.deletePreview.project_count+" project link(s) and "+root.deletePreview.summary_count+" cached summary." : "";Layout.fillWidth:true}
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(8)
                    Icon {theme:ui;name:"check";size:ui.title;color:ui.accentText}
                    BibLabel {text:"PDF files stay on disk. There is no in-app undo.";color:ui.muted;Layout.fillWidth:true}
                }
                BibLabel {visible:root.error!=="";text:root.error;color:ui.urgent;Layout.fillWidth:true}
                RowLayout {Layout.fillWidth:true;Layout.topMargin:ui.space(6);spacing:ui.space(8);Item{Layout.fillWidth:true}BibButton{variant:"ghost";text:"Cancel";enabled:!root.deleteBusy;onClicked:deleteDialog.close()}BibButton{variant:"danger";iconName:"trash";text:root.deleteBusy?"Deleting…":"Delete item";shortcutHint:"^↵";enabled:!root.deleteBusy;onClicked:root.confirmDelete()}}
            }
            Shortcut {sequence:"Ctrl+Return";enabled:deleteDialog.opened&&!root.deleteBusy;onActivated:root.confirmDelete()}
        }
        BibDialog {
            id:noteDeleteDialog;title:"Delete note";iconName:"trash";anchors.centerIn:parent;width:Math.min(500,window.width-60);modal:true;closePolicy:Popup.CloseOnEscape
            onClosed:{if(!root.noteDeleteBusy)root.noteDeletePreview=null}
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(12)
                RowLayout {
                    spacing:ui.space(8)
                    Chip {theme:ui;icon:"folder";text:root.noteDeletePreview ? root.noteDeletePreview.project_name : ""}
                    Chip {theme:ui;text:root.noteDeletePreview ? root.noteDeletePreview.citekey : ""}
                }
                Text {text:root.noteDeletePreview ? (root.noteDeletePreview.excerpt||"Image-only note") : "";color:ui.bright;font.family:ui.readingFamily;font.pixelSize:ui.subtitle;lineHeight:1.4;wrapMode:Text.Wrap;elide:Text.ElideRight;maximumLineCount:4;Layout.fillWidth:true;textFormat:Text.PlainText}
                BibLabel {text:root.noteDeletePreview&&root.noteDeletePreview.has_image ? "Its saved image clip and revisions will also be deleted." : "Its revisions will also be deleted.";color:ui.muted;Layout.fillWidth:true}
                BibLabel {visible:root.error!=="";text:root.error;color:ui.urgent;Layout.fillWidth:true}
                RowLayout {Layout.fillWidth:true;Layout.topMargin:ui.space(6);spacing:ui.space(8);Item{Layout.fillWidth:true}BibButton{variant:"ghost";text:"Cancel";enabled:!root.noteDeleteBusy;onClicked:noteDeleteDialog.close()}BibButton{variant:"danger";iconName:"trash";text:root.noteDeleteBusy?"Deleting…":"Delete note";shortcutHint:"^↵";enabled:!root.noteDeleteBusy;onClicked:root.confirmNoteDelete()}}
            }
            Shortcut {sequence:"Ctrl+Return";enabled:noteDeleteDialog.opened&&!root.noteDeleteBusy;onActivated:root.confirmNoteDelete()}
        }
        BibDialog {
            id:bibFileDialog
            title:root.pickerKind==="pdf"?"Attach PDF to reference":"Import BibTeX file"
            iconName:root.pickerKind==="pdf"?"pdf":"braces"
            anchors.centerIn:parent;width:Math.min(760,window.width-60);height:Math.min(620,window.height-60);modal:true
            property string basePath: Quickshell.env("HOME")+"/"
            property string wantedFolder: ""
            property string fragment: ""
            property var matches: []
            property string lastChosen: ""
            onOpened:{updateMatches();Qt.callLater(function(){filePath.forceActiveFocus();filePath.selectAll()})}
            function updateMatches() {
                matches=[]
                var path=filePath.text
                if(path==="~" || path.startsWith("~/"))path=Quickshell.env("HOME")+path.slice(1)
                var slash=path.lastIndexOf("/")
                var directory=slash<0?basePath:path.slice(0,slash+1)
                if(!directory.startsWith("/"))directory=basePath+directory
                wantedFolder=root.fileUrl(directory)
                fragment=(slash<0?path:path.slice(slash+1)).toLocaleLowerCase()
                if(folders.folder.toString()!==wantedFolder)folders.folder=wantedFolder
                filterTimer.restart()
            }
            function filterMatches() {
                if(folders.status!==FolderListModel.Ready)return
                var words=fragment.split(/\s+/).filter(function(w){return w.length>0})
                var found=[]
                for(var i=0;i<folders.count;++i){
                    var name=folders.get(i,"fileName")
                    var lower=name.toLocaleLowerCase()
                    var isDir=folders.get(i,"fileIsDir")
                    if(!isDir && !(root.pickerKind==="pdf"?lower.endsWith(".pdf"):(lower.endsWith(".bib")||lower.endsWith(".bibtex"))))continue
                    if(!words.every(function(w){return lower.indexOf(w)>=0}))continue
                    found.push({name:name,url:folders.get(i,"fileUrl").toString(),isDir:folders.get(i,"fileIsDir")})
                }
                var previous=fileList.currentIndex>=0&&matches[fileList.currentIndex]?matches[fileList.currentIndex].url:""
                matches=found
                var keep=found.findIndex(function(m){return m.url===previous})
                fileList.currentIndex=keep>=0?keep:(found.length?0:-1)
            }
            function go(url) {
                basePath=decodeURIComponent(url.slice(7)).replace(/\/+$/,"")+"/"
                filePath.text=basePath
                updateMatches()
                filePath.forceActiveFocus();filePath.cursorPosition=filePath.text.length
            }
            function choose(index) {
                if(index<0 || index>=matches.length)return
                var item=matches[index]
                lastChosen=item.name
                if(item.isDir)go(item.url)
                else{close();root.acceptFile(item.url)}
            }
            function navigate(delta) {
                if(!matches.length)return
                fileList.currentIndex=Math.max(0,Math.min(matches.length-1,fileList.currentIndex+delta))
                fileList.positionViewAtIndex(fileList.currentIndex,ListView.Contain)
            }
            Timer {id:filterTimer;interval:20;onTriggered:bibFileDialog.filterMatches()}
            FolderListModel {
                id:folders
                folder:root.fileUrl(Quickshell.env("HOME"))
                nameFilters:["*"]
                showDirs:true;showDirsFirst:true;showDotAndDotDot:false;showHidden:false
                onCountChanged:filterTimer.restart()
                onStatusChanged:{if(status===FolderListModel.Ready)filterTimer.restart();else bibFileDialog.matches=[]}
                onFolderChanged:filterTimer.restart()
            }
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(10)
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(6)
                    IconButton {theme:ui;icon:"folderUp";size:ui.space(32);tooltip:"Parent folder";shortcut:"Alt+Up";onClicked:bibFileDialog.go(folders.parentFolder.toString())}
                    BibField {
                        id:filePath
                        Layout.fillWidth:true
                        text:Quickshell.env("HOME")+"/"
                        placeholderText:"Type part of a folder or filename…"
                        onTextChanged:bibFileDialog.updateMatches()
                        onAccepted:bibFileDialog.choose(fileList.currentIndex)
                        Keys.onPressed:function(event){if((event.modifiers&Qt.ControlModifier)&&event.key===Qt.Key_L){selectAll();event.accepted=true}}
                        Keys.onDownPressed:bibFileDialog.navigate(1)
                        Keys.onUpPressed:bibFileDialog.navigate(-1)
                    }
                }
                BibLabel {visible:bibFileDialog.matches.length===0;text:folders.status===FolderListModel.Loading?"Loading folder…":"No matching folders or files";color:ui.dim;Layout.fillWidth:true}
                ListView {
                    id:fileList
                    Layout.fillWidth:true;Layout.fillHeight:true;clip:true
                    model:bibFileDialog.matches;currentIndex:0
                    boundsBehavior:Flickable.StopAtBounds
                    delegate:Rectangle {
                        id:fileRow
                        required property int index
                        required property var modelData
                        width:ListView.view.width
                        height:ui.space(30)
                        color:fileList.currentIndex===index?ui.line:fileMouse.containsMouse?ui.hoverFill:"transparent"
                        Rectangle {visible:fileList.currentIndex===fileRow.index;anchors{left:parent.left;top:parent.top;bottom:parent.bottom}width:2;color:ui.accent}
                        RowLayout {
                            anchors{fill:parent;leftMargin:ui.space(10);rightMargin:ui.space(10)}
                            spacing:ui.space(10)
                            Icon {theme:ui;name:fileRow.modelData.isDir?"folder":root.pickerKind==="pdf"?"pdf":"braces";size:ui.title;color:fileRow.modelData.isDir?ui.muted:ui.accentText}
                            Text {Layout.fillWidth:true;text:fileRow.modelData.name;color:fileList.currentIndex===fileRow.index?ui.bright:ui.text;font.family:ui.mono;font.pixelSize:ui.body;elide:Text.ElideMiddle;textFormat:Text.PlainText}
                            Icon {theme:ui;visible:fileRow.modelData.isDir;name:"chevronRight";size:ui.title;color:ui.dim}
                        }
                        MouseArea {id:fileMouse;anchors.fill:parent;hoverEnabled:true;onClicked:{fileList.currentIndex=fileRow.index;bibFileDialog.choose(fileRow.index)}}
                    }
                    Keys.onReturnPressed:bibFileDialog.choose(currentIndex)
                    ScrollBar.vertical:ScrollBar{contentItem:Rectangle{implicitWidth:ui.space(4);color:ui.line}}
                }
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(8)
                    BibLabel{text:"Type to filter · ↑↓ select · ↵ open · Ctrl+L path";color:ui.dim;font.pixelSize:ui.small;Layout.fillWidth:true}
                    BibButton{variant:"ghost";text:"Cancel";onClicked:bibFileDialog.close()}
                    BibButton{variant:"primary";text:fileList.currentIndex>=0&&bibFileDialog.matches[fileList.currentIndex]&&!bibFileDialog.matches[fileList.currentIndex].isDir?(root.pickerKind==="pdf"?"Attach PDF":"Import file"):"Open folder";enabled:bibFileDialog.matches.length>0;onClicked:bibFileDialog.choose(fileList.currentIndex)}
                }
            }
            Shortcut {sequence:"Ctrl+L";enabled:bibFileDialog.opened;onActivated:{filePath.forceActiveFocus();filePath.selectAll()}}
            Shortcut {sequence:"Alt+Up";enabled:bibFileDialog.opened;onActivated:bibFileDialog.go(folders.parentFolder.toString())}
        }
        BibDialog {
            id:repoDialog;title:"History repository";iconName:"branch";anchors.centerIn:parent;width:Math.min(720,window.width-60);modal:true
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(8)
                Flow {
                    Layout.fillWidth:true;spacing:ui.space(6)
                    Repeater {
                        model:root.repoChecks()
                        Chip {required property var modelData;theme:ui;icon:modelData[1]?"check":"alert";iconColor:modelData[1]?ui.accentText:ui.urgent;text:modelData[0]+(modelData[2]?" · "+modelData[2]:"")}
                    }
                    BibLabel {visible:root.repoChecks().length===0;text:"Checking git, git-lfs and gh…";color:ui.dim}
                }
                SectionLabel {theme:ui;text:"Checkout";Layout.topMargin:ui.space(6)}
                BibLabel{text:"Path: an existing checkout, or where to create a new one";color:ui.muted}
                RowLayout{Layout.fillWidth:true;spacing:ui.space(6);BibField{id:repoPath;Layout.fillWidth:true;placeholderText:"/absolute/path/to/history";onEditingFinished:root.checkRepoPrereqs()}BibButton{text:"Check";iconName:"refresh";onClicked:root.checkRepoPrereqs()}}
                BibLabel{text:"Branch";color:ui.muted}
                BibField{id:repoBranch;Layout.fillWidth:true;text:"main"}
                BibLabel{text:root.error;visible:text!=="";color:ui.urgent;Layout.fillWidth:true}
                SectionLabel {theme:ui;text:"New private GitHub repository";Layout.topMargin:ui.space(8)}
                RowLayout{Layout.fillWidth:true;spacing:ui.space(6);BibField{id:repoNewName;Layout.fillWidth:true;placeholderText:"omabib-history"}BibButton{variant:"primary";iconName:"plus";text:root.repoBusy?"Working…":"Create";enabled:!root.repoBusy&&root.repoCheck.gh_logged_in===true;onClicked:root.createGithubRepo()}}
                SectionLabel {theme:ui;text:"Or use an existing checkout";Layout.topMargin:ui.space(8)}
                BibLabel{text:"Remote URL (origin), blank keeps the checkout's own";color:ui.muted}
                BibField{id:repoRemote;Layout.fillWidth:true;placeholderText:"https://github.com/owner/repository.git"}
                BibLabel{text:"Sync exports the local library and pushes it. Git LFS is set up automatically when it isn't tracking PDFs yet. Remote metadata is never merged into SQLite.";color:ui.dim;font.pixelSize:ui.small;Layout.fillWidth:true}
                RowLayout {Layout.fillWidth:true;Layout.topMargin:ui.space(6);spacing:ui.space(8);Item{Layout.fillWidth:true}BibButton{variant:"ghost";text:"Cancel";onClicked:repoDialog.close()}BibButton{variant:"primary";text:root.repoBusy?"Working…":"Use this checkout";enabled:!root.repoBusy;onClicked:root.useLocalRepo()}}
            }
        }
        BibDialog {
            id:projectDialog;title:"Assign to project";iconName:"folder";anchors.centerIn:parent;width:420;height:Math.min(window.height-60,460);modal:true
            onOpened:projectList.forceActiveFocus()
            ListView {
                id:projectList
                anchors.fill:parent
                clip:true;model:root.projects;currentIndex:0
                boundsBehavior:Flickable.StopAtBounds
                delegate:Rectangle {
                    id:projectRow
                    required property var modelData
                    required property int index
                    width:ListView.view.width;height:ui.space(34)
                    color:ListView.isCurrentItem?ui.line:projectMouse.containsMouse?ui.hoverFill:"transparent"
                    Rectangle {visible:projectRow.ListView.isCurrentItem;anchors{left:parent.left;top:parent.top;bottom:parent.bottom}width:2;color:ui.accent}
                    RowLayout {
                        anchors{fill:parent;leftMargin:ui.space(12);rightMargin:ui.space(12)}
                        spacing:ui.space(10)
                        Icon {theme:ui;name:"folder";size:ui.title;color:projectRow.ListView.isCurrentItem?ui.accentText:ui.muted}
                        Text {Layout.fillWidth:true;text:projectRow.modelData.name;color:projectRow.ListView.isCurrentItem?ui.bright:ui.text;font.family:ui.mono;font.pixelSize:ui.body;elide:Text.ElideRight;textFormat:Text.PlainText}
                    }
                    MouseArea {id:projectMouse;anchors.fill:parent;hoverEnabled:true;onClicked:root.assignToProject(projectRow.index)}
                }
                Keys.onReturnPressed:root.assignToProject(currentIndex)
            }
        }
        BibDialog {
            id:editorDialog;anchors.centerIn:parent
            iconName:root.editKind==="note"?(root.editingNote?"pencil":"notePlus"):root.editKind==="metadata"||root.editKind==="import"?"braces":root.editKind==="quick"?"plus":root.editKind==="doi"?"link":root.editKind==="project"?"folderOpen":"pdf"
            width:Math.min(760,window.width-60)
            height:Math.min(root.editKind==="quick"||root.editKind==="doi"||root.editKind==="project"?340:640,window.height-60)
            leftPadding:ui.space(20)
            rightPadding:ui.space(20)
            modal:true;closePolicy:Popup.CloseOnEscape
            onClosed:{if(root.inPdfTab)Qt.callLater(root.focusActiveTab)}
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(8)
                Text {visible:root.editKind==="note";text:root.noteTargetTitle;color:ui.bright;font.family:ui.readingFamily;font.pixelSize:ui.subtitle;font.weight:Font.DemiBold;elide:Text.ElideRight;maximumLineCount:1;Layout.fillWidth:true;textFormat:Text.PlainText}
                BibLabel {visible:root.editKind==="quick";text:"Paste a DOI, arXiv ID or URL (several at once work too), or a whole BibTeX entry. Omabib looks up the metadata, abstract and an open-access PDF.";color:ui.muted;Layout.fillWidth:true}
                RowLayout {
                    visible:root.editKind==="note"
                    Layout.fillWidth:true;spacing:ui.space(8)
                    BibLabel {text:"Scope";color:ui.muted}
                    BibCombo{id:noteScope;model:["Global · all projects"].concat(root.projects.map(function(p){return p.name}));Layout.fillWidth:true}
                }
                NoteEditor {
                    id:noteEditor;objectName:"noteEditor"
                    visible:root.editKind==="note"
                    Layout.fillWidth:true;Layout.fillHeight:true
                    theme:ui;app:root
                    placeholderText:"What matters about this paper for the project?"
                }
                ScrollView {
                    visible:root.editKind!=="note"
                    Layout.fillWidth:true;Layout.fillHeight:true
                    BibTextArea{
                        id:editor;objectName:"editor"
                        placeholderText:root.editKind==="quick"?"10.1038/…   2609.07987   https://…   @article{…}":root.editKind==="doi"?"10.xxxx/…":root.editKind==="attachment"?"/absolute/path/to/paper.pdf":root.editKind==="project"?"Project name":""
                    }
                }
                BibField{id:labels;visible:root.editKind==="note";placeholderText:"Labels, separated by commas";Layout.fillWidth:true}
                BibField{id:evidence;visible:root.editKind==="note";placeholderText:"Evidence location, e.g. PDF p. 7, Table 2";Layout.fillWidth:true}
                BibLabel{visible:root.error!=="";text:root.error;color:ui.urgent;Layout.fillWidth:true}
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(8)
                    BibLabel{text:"";Layout.fillWidth:true}
                    BibButton{variant:"ghost";text:"Cancel";onClicked:editorDialog.close()}
                    BibButton{variant:"primary";text:(root.editKind==="doi"||root.editKind==="quick")?(root.noteSaving?"Looking up…":"Preview"):(root.noteSaving?"Saving…":"Save");shortcutHint:"^↵";enabled:!root.noteSaving;onClicked:root.saveEditor()}
                }
            }
            Shortcut{sequence:"Ctrl+Return";enabled:editorDialog.opened;onActivated:root.saveEditor()}
        }
        BibDialog {
            id:metadataDialog;title:"Fill metadata online";iconName:"refresh";anchors.centerIn:parent;width:Math.min(780,window.width-60);height:Math.min(680,window.height-60);modal:true
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(10)
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(8)
                    Icon {theme:ui;visible:root.metadataBusy;name:"refresh";size:ui.title;color:ui.accentText;RotationAnimation on rotation {running:root.metadataBusy;from:0;to:360;duration:900;loops:Animation.Infinite}}
                    BibLabel {text:root.metadataBusy?"Looking up metadata…":root.metadataInfo;color:ui.muted;Layout.fillWidth:true}
                }
                RowLayout {
                    Layout.fillWidth:true;spacing:ui.space(6)
                    BibCombo {
                        id:metadataCandidates;Layout.fillWidth:true
                        model:root.metadataLookup?root.metadataLookup.candidates.map(function(c){return (c.fields.title||"Untitled")+" · "+(c.fields.year||"")+" · "+(c.fields.author||"")}):[]
                        enabled:!root.metadataBusy && count>0
                        onActivated:root.selectMetadata(currentIndex)
                    }
                    BibButton {text:"Review match";enabled:!root.metadataBusy && metadataCandidates.count>0;onClicked:root.selectMetadata(metadataCandidates.currentIndex)}
                }
                ScrollView {
                    Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumHeight:0;clip:true
                    BibTextArea {readOnly:true;text:root.metadataPreviewText()}
                }
                RowLayout {Layout.fillWidth:true;spacing:ui.space(8);BibLabel{text:"Existing values are never overwritten";color:ui.dim;font.pixelSize:ui.small;Layout.fillWidth:true}BibButton{variant:"ghost";text:"Cancel";onClicked:metadataDialog.close()}BibButton{variant:"primary";text:"Fill missing fields";shortcutHint:"^↵";enabled:root.metadataChoice!==null&&!root.metadataBusy;onClicked:root.applyMetadata()}}
            }
            Shortcut {sequence:"Ctrl+Return";enabled:metadataDialog.opened&&!root.metadataBusy&&root.metadataChoice!==null;onActivated:root.applyMetadata()}
        }
        BibDialog {
            id:previewDialog
            Shortcut {sequence:"Ctrl+Return";enabled:previewDialog.opened&&root.pendingImport!==null;onActivated:root.importPreview()}
            title:root.pendingImport?"Add to library":"Import report";iconName:root.pendingImport?"plus":"check"
            anchors.centerIn:parent;width:Math.min(760,window.width-60);height:Math.min(root.previewItem?660:600,window.height-60);modal:true
            ColumnLayout {
                anchors.fill:parent;spacing:ui.space(12)
                ScrollPane {
                    id:previewCard
                    visible:root.previewItem!==null
                    Layout.fillWidth:true;Layout.fillHeight:true
                    theme:ui;measure:ui.space(2000);sidePadding:0;topPadding:0
                    readonly property var item: root.previewItem || ({})
                    readonly property string abstractText: Format.bibField(item.bibtex, "abstract")
                    readonly property string venueText: Format.bibField(item.bibtex, "journal") || Format.bibField(item.bibtex, "booktitle") || Format.bibField(item.bibtex, "publisher")
                    RowLayout {
                        Layout.fillWidth:true;spacing:ui.space(8)
                        Text {Layout.maximumWidth:previewCard.width*0.6;text:previewCard.item.input||"";color:ui.muted;font.family:ui.mono;font.pixelSize:ui.small;elide:Text.ElideMiddle;textFormat:Text.PlainText}
                        Chip {theme:ui;icon:"check";iconColor:ui.accentText;text:(previewCard.item.recognized==="doi"?"DOI":previewCard.item.recognized==="arxiv"?"arXiv ID":previewCard.item.recognized==="url"?"Web page":String(previewCard.item.recognized||""))+" recognized";bordered:false}
                        Item {Layout.fillWidth:true}
                    }
                    Text {Layout.fillWidth:true;text:previewCard.item.title||previewCard.item.citekey||"";color:ui.bright;font.family:ui.readingFamily;font.pixelSize:ui.heading+4;font.weight:Font.DemiBold;lineHeight:1.15;wrapMode:Text.Wrap;textFormat:Text.PlainText}
                    Text {Layout.fillWidth:true;Layout.topMargin:-ui.space(6);visible:text!=="";text:Format.fullAuthors(previewCard.item.authors,10);color:ui.text;font.family:ui.readingFamily;font.pixelSize:ui.subtitle;wrapMode:Text.Wrap;textFormat:Text.PlainText}
                    Text {Layout.fillWidth:true;Layout.topMargin:-ui.space(6);visible:text!=="";text:[previewCard.venueText,previewCard.item.year].filter(function(s){return !!s}).join("  ·  ");color:ui.muted;font.family:ui.mono;font.pixelSize:ui.small;textFormat:Text.PlainText}
                    Text {Layout.fillWidth:true;visible:previewCard.abstractText!=="";text:previewCard.abstractText;color:ui.text;font.family:ui.readingFamily;font.pixelSize:ui.subtitle;lineHeight:1.5;wrapMode:Text.Wrap;maximumLineCount:6;elide:Text.ElideRight;textFormat:Text.PlainText}
                    Flow {
                        Layout.fillWidth:true;spacing:ui.space(6)
                        Chip {theme:ui;icon:previewCard.item.abstract_source?"text":"alert";iconColor:previewCard.item.abstract_source?ui.accentText:ui.urgent;text:previewCard.item.abstract_source?"abstract · "+previewCard.item.abstract_source:"no abstract found"}
                        Chip {theme:ui;icon:previewCard.item.pdf_url?"pdf":"fileMissing";iconColor:previewCard.item.pdf_url?ui.accentText:ui.dim;text:previewCard.item.pdf_url?"open PDF · "+Format.host(previewCard.item.pdf_url):"no open-access PDF"}
                        Chip {theme:ui;icon:"tag";visible:!!previewCard.item.citekey;text:previewCard.item.citekey||""}
                        Chip {theme:ui;icon:"folder";visible:root.projectId!=="";text:"adds to "+root.projectName}
                    }
                    RowLayout {
                        Layout.fillWidth:true;Layout.topMargin:ui.space(4);spacing:ui.space(6)
                        Icon {theme:ui;name:root.previewShowBibtex?"chevronDown":"chevronRight";size:ui.title;color:ui.muted}
                        SectionLabel {theme:ui;text:"BibTeX to import"}
                        Item {Layout.fillWidth:true}
                        TapHandler {onTapped:root.previewShowBibtex=!root.previewShowBibtex}
                        HoverHandler {cursorShape:Qt.PointingHandCursor}
                    }
                    Rectangle {
                        visible:root.previewShowBibtex
                        Layout.fillWidth:true
                        implicitHeight:previewBib.implicitHeight+ui.space(24)
                        color:ui.app;border.width:1;border.color:ui.line;radius:ui.radius
                        TextEdit {id:previewBib;anchors{left:parent.left;right:parent.right;top:parent.top;margins:ui.space(12)}readOnly:true;selectByMouse:true;wrapMode:TextEdit.WrapAtWordBoundaryOrAnywhere;text:previewCard.item.bibtex||"";color:ui.text;font.family:ui.mono;font.pixelSize:ui.small;textFormat:TextEdit.PlainText;selectionColor:Qt.rgba(ui.accent.r,ui.accent.g,ui.accent.b,0.55)}
                    }
                    Repeater {
                        model:root.pendingImport?(root.pendingImport.warnings||[]).concat(previewCard.item.warnings||[]):[]
                        BibLabel {required property var modelData;text:"⚠ "+modelData;color:ui.dim;font.pixelSize:ui.small;Layout.fillWidth:true}
                    }
                }
                ScrollView{visible:root.previewItem===null;Layout.fillWidth:true;Layout.fillHeight:true;BibTextArea{id:previewBody;readOnly:true}}
                RowLayout{
                    Layout.fillWidth:true;spacing:ui.space(8)
                    BibLabel{text:root.pendingImport?"Existing values are never overwritten":"";color:ui.dim;font.pixelSize:ui.small;Layout.fillWidth:true}
                    BibButton{variant:"ghost";visible:root.pendingImport!==null;iconName:"pencil";text:"Edit BibTeX";onClicked:root.editPreviewBibtex()}
                    BibButton{variant:"ghost";text:root.pendingImport?"Cancel":"Close";onClicked:previewDialog.close()}
                    BibButton{variant:"primary";visible:root.pendingImport!==null;iconName:"plus";text:root.noteSaving?"Adding…":"Add to library";shortcutHint:"^↵";enabled:!root.noteSaving;onClicked:root.importPreview()}
                }
            }
        }
    }
}
