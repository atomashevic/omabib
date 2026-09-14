import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Qt.labs.folderlistmodel
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
    id: root
    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool expanded: false
    property var projects: []
    property var hits: []
    property string browseSort: "added_desc"
    property var selected: null
    property var deletePreview: null
    property bool deleteBusy: false
    property int deleteRequest: -1
    property var noteDeletePreview: null
    property bool noteDeleteBusy: false
    property int noteDeleteRequest: -1
    property string pendingOpenRefId: ""
    property bool codexBusy: false
    property var readingContext: null
    property bool quickNoteMode: false
    property var quickNoteContext: null
    property string noteTargetId: ""
    property string noteTargetTitle: ""
    property int noteSaveRequest: -1
    property bool noteSaving: false
    property string clipPath: ""
    property var clipRectangle: null
    property bool captureBusy: false
    property var pendingQuickNote: null
    property string projectId: ""
    property string serviceSocket: Quickshell.env("OMABIB_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/omabib/socket")
    readonly property string pdfShortcut: Quickshell.env("OMABIB_PDF_SHORTCUT") || "Ctrl+O"
    property string projectName: "All references"
    property string assignTargetId: ""
    property string overviewRefId: ""
    property string overviewBody: ""
    property string overviewUrl: ""
    property bool overviewVisible: false
    property bool overviewBusy: false
    property string overviewRequestId: ""
    property bool allNotes: false
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
    readonly property color bg: Color.menu.background
    readonly property color fg: Color.menu.text
    readonly property color borderColor: Color.menu.border
    readonly property color selectedBg: Color.menu.selectedBackground
    readonly property color selectedFg: Color.menu.selectedText
    readonly property string fontFamily: Style.font.menuFamily

    component BibButton: Button {
        id: control
        property bool textLeft: false
        implicitHeight: 32
        implicitWidth: contentItem.implicitWidth + 20
        padding: 8
        contentItem: Text { text: control.text; color: control.enabled ? root.fg : Color.muted; font.family: root.fontFamily; font.pixelSize: 12; horizontalAlignment: control.textLeft ? Text.AlignLeft : Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { color: control.down || control.hovered || control.activeFocus ? root.selectedBg : "transparent"; radius: 4; border.color: root.borderColor; border.width: control.activeFocus ? 2 : 1 }
    }
    component BibDialog: Dialog {
        palette.window: root.bg
        palette.windowText: root.fg
        palette.base: root.bg
        palette.text: root.fg
        palette.button: root.bg
        palette.buttonText: root.fg
        palette.highlight: root.selectedBg
        palette.highlightedText: root.selectedFg
        palette.placeholderText: Color.muted
        background: Rectangle { color: root.bg; border.color: root.borderColor; radius: Style.cornerRadius }
    }
    function open(payloadJson) {
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
        if(payload.action==="quick_note") { openQuickNote(payload); return }
        if(editorDialog.opened) { editor.forceActiveFocus(); return }
        if(payload.socket_path && payload.socket_path!==serviceSocket){readingContext=null;overviewRefId="";overviewBody="";overviewUrl="";overviewVisible=false;socket.connected=false;serviceSocket=payload.socket_path;Qt.callLater(function(){socket.connected=true})}
        pendingOpenRefId=payload.ref_id||""
        if(pendingOpenRefId){authorFilter.text="";yearFilter.text="";typeFilter.text="";labelFilter.text=""}
        if(payload.query!==undefined) query.text=payload.query
        if (payload.project_id !== undefined) projectId = payload.project_id || ""
        openedAt = Date.now()
        openPending = true
        opened = true
        if (socket.connected) refresh()
        else socket.connected = true
        Qt.callLater(function() { if(payload.action==="add"){commandDialog.close();bibFileDialog.close();metadataDialog.close();previewDialog.close();repoDialog.close();projectDialog.close();if(editorDialog.opened)editor.forceActiveFocus();else edit("quick");}else{query.forceActiveFocus(); query.selectAll()} })
    }
    function close() {
        opened = false
        if(quickNoteMode) { quickNoteMode=false; editorDialog.close() }
    }
    function readingTarget(hit) {
        return hit ? {ref_id:hit.id,project_id:projectId,socket_path:serviceSocket} : null
    }
    function discardClip(path) {
        if(path)Quickshell.execDetached(["omabib-capture-note","--discard",path])
    }
    function captureClip() {
        if(!quickNoteMode || captureBusy || noteSaving)return
        error=""
        captureBusy=true
        clipStart.restart()
    }
    Timer {id:clipStart;interval:80;onTriggered:{clipCapture.command=["omabib-capture-note",JSON.stringify(root.quickNoteContext)];clipCapture.running=true}}
    Process {
        id:clipCapture
        stdout:SplitParser {
        onRead: data => {
            var result={}
            try{result=JSON.parse(data)}catch(e){result.error="Capture did not return an image"}
            root.captureBusy=false
            if(!root.opened || !root.quickNoteMode){root.discardClip(result.path);return}
            if(result.path){root.discardClip(root.clipPath);root.clipPath=result.path;root.clipRectangle=result.rectangle}
            else if(result.error)root.error=result.error
            Qt.callLater(function(){editor.forceActiveFocus()})
        }
        }
    }
    function openQuickNote(payload) {
        if(editorDialog.opened) { editor.forceActiveFocus(); return }
        if(!payload.ref_id || !payload.socket_path || !Number.isInteger(payload.page) || payload.page<1) return
        if(payload.socket_path!==serviceSocket || !socket.connected) {
            pendingQuickNote=payload
            overviewRefId="";overviewBody="";overviewUrl="";overviewVisible=false
            socket.connected=false
            serviceSocket=payload.socket_path
            Qt.callLater(function(){socket.connected=true})
            return
        }
        readingContext={ref_id:payload.ref_id,project_id:payload.project_id||"",socket_path:payload.socket_path}
        quickNoteContext=payload
        quickNoteMode=true
        opened=true
        error=""
        rpc("list_projects",{},function(r){
            if(!opened || !quickNoteMode || quickNoteContext!==payload)return
            projects=r.projects
            rpc("get_reference",{id:payload.ref_id,include_attachments:true},function(ref){
                if(!opened || !quickNoteMode || quickNoteContext!==payload)return
                selected=ref
                edit("note",null)
                editorDialog.title="Note  ·  p. "+payload.page
                if(payload.clip && payload.clip.path){clipPath=payload.clip.path;clipRectangle=payload.clip.rectangle}
                evidence.text="PDF p. "+payload.page+" · "+payload.pdf_path
                noteScope.currentIndex=0
                for(var i=0;i<projects.length;i++)if(projects[i].id===payload.project_id)noteScope.currentIndex=i+1
            })
        })
    }
    function fileUrl(path) { return "file://" + path.split("/").map(encodeURIComponent).join("/") }
    function openExternal(url, context) {
        readingContext=context || readingTarget(selected || currentHit())
        // The browser launcher explicitly focuses an existing browser window.
        // Drop our exclusive layer focus before starting either application.
        dismiss()
        if(/^https?:\/\//i.test(url)) {
            Quickshell.execDetached(["omarchy-launch-browser", url])
        } else {
            Qt.callLater(function() {
                if(!Qt.openUrlExternally(url)) {
                    error="Could not open "+url
                    if(shell && shell.summon) shell.summon("omabib", "{}")
                }
            })
        }
    }
    function openPdf() {
        var hit=currentHit();if(!hit)return
        var context=readingTarget(hit)
        rpc("open_target",{id:hit.id},function(r){openExternal(r.url,context)})
    }
    function openLink() {
        var hit=currentHit();if(!hit)return
        var context=readingTarget(hit)
        rpc("open_target",{id:hit.id,prefer:"link"},function(r){openExternal(r.url,context)})
    }
    // Reads the arXiv ID off a fetched reference's own fields (its DOI, if
    // inferred from arXiv, or a url/eprint field), for the AlphaXiv link —
    // purely client-side since it's just a URL, no RPC needed.
    function arxivIdOf(ref) {
        if(!ref || !ref.fields)return ""
        var doi=ref.fields.doi||""
        var m=/^10\.48550\/arxiv\.(.+)$/i.exec(doi)
        if(m)return m[1]
        var s=(ref.fields.url||"")+" "+(ref.fields.eprint||"")
        m=/arxiv\.org\/(?:abs|pdf)\/([^\s?#]+)/i.exec(s)
        if(m)return m[1].replace(/\.pdf$/i,"")
        if(/^\d{4}\.\d{4,5}(v\d+)?$/.test(ref.fields.eprint||""))return ref.fields.eprint
        return ""
    }
    function openCodex(desktop) {
        var hit=currentHit()
        if(!hit || codexBusy)return
        codexBusy=true;error=""
        codexProcess.command=[desktop?"omabib-chatgpt":"omabib-codex",serviceSocket,hit.id,projectId||""]
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
        if(!id){notice="Not recognized as an arXiv paper";noticeTimer.restart();return}
        openExternal("https://www.alphaxiv.org/abs/"+id)
    }
    function showAlphaXivOverview() {
        if(!selected || overviewBusy)return
        if(overviewRefId===selected.id && overviewBody){overviewVisible=!overviewVisible;return}
        overviewRequestId=selected.id
        overviewBusy=true
        overviewProcess.command=["omabib-overview",serviceSocket,selected.id]
        overviewProcess.running=true
    }
    Process {
        id:overviewProcess
        stdout:SplitParser {onRead:data=>{
            var r={}
            try{r=JSON.parse(data)}catch(e){r.error="Invalid AlphaXiv response"}
            root.overviewBusy=false
            if(r.error){root.notice="AlphaXiv: "+r.error;noticeTimer.restart();return}
            if(!r.available){root.notice="No AlphaXiv AI Overview available";noticeTimer.restart();return}
            if(!root.selected || root.selected.id!==root.overviewRequestId)return
            root.overviewRefId=root.overviewRequestId
            root.overviewBody=r.body
            root.overviewUrl=r.source_url
            root.overviewVisible=true
        }}
        onExited:(code,status)=>{if(root.overviewBusy){root.overviewBusy=false;root.notice="AlphaXiv overview could not be loaded";noticeTimer.restart()}}
    }
    property bool pdfBusy: false
    property int pdfRequest: -1
    function getPdf() {
        var hit=currentHit();if(!hit||pdfBusy)return
        var context=readingTarget(hit)
        pdfBusy=true
        pdfRequest=rpc("get_pdf",{ref_id:hit.id},function(r){
            pdfBusy=false
            openExternal(root.fileUrl(r.path),context)
        })
        if(pdfRequest<0)pdfBusy=false
    }
    function copyPdfPath() {
        var hit=currentHit();if(!hit)return
        rpc("get_pdf",{ref_id:hit.id,download:false},function(r){copy(r.path)})
    }
    function lookupMetadata() {
        var hit=currentHit();if(!hit || metadataBusy)return
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
    function applyMetadata() {
        if(!metadataChoice || metadataBusy)return
        metadataBusy=true
        metadataRequest=rpc("apply_metadata",{id:metadataLookup.id,expected_revision:metadataLookup.expected_revision,fields:metadataChoice.additions,source:metadataChoice.source},function(r){metadataDialog.close();refresh();notice="Filled "+r.filled.length+" metadata fields";noticeTimer.restart()})
    }
    function dismiss() {
        close()
        if (shell && shell.hide) shell.hide("omabib")
    }
    function rpc(method, params, callback) {
        if (!socket.connected) { error = "Omabib service is unavailable. Start it with systemctl --user start omabib."; return -1 }
        var id = ++sequence
        if(method==="search"){if(pendingSearch!==-1)delete pending[pendingSearch];pendingSearch=id}
        pending[id] = callback || function() {}
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
    }
    function relativeTime(iso) {
        if(!iso)return ""
        var ms=Date.now()-Date.parse(iso)
        if(isNaN(ms))return ""
        var s=Math.floor(ms/1000)
        if(s<60)return "just now"
        var m=Math.floor(s/60);if(m<60)return m+"m ago"
        var h=Math.floor(m/60);if(h<24)return h+"h ago"
        return Math.floor(h/24)+"d ago"
    }
    function syncChipText() {
        if(root.syncBusy)return "Syncing…"
        var s=root.repoStatus
        if(!s || s.configured!==true)return "Set up sync"
        if(s.last_error)return "⚠ Sync issue"
        if(s.pending && s.pending.any)return "● Changes pending"
        if(s.behind>0)return "↓ "+s.behind+" behind"
        return "✓ Synced "+root.relativeTime(s.last_success)
    }
    function updateProjectName() {
        projectName = "All references"
        for (var i=0; i<projects.length; ++i) if (projects[i].id===projectId) projectName = projects[i].name
    }
    function toggleBrowseSort() {
        if(query.text.trim()!=="")return
        browseSort = browseSort==="added_desc" ? "citekey" : "added_desc"
        search(false)
        query.forceActiveFocus()
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
        rpc("search", args, function(r) {
            if (serial !== searchSequence) return
            searchPending = false
            hits = append ? hits.concat(r.results) : r.results
            nextCursor = r.next_cursor
            if (!append) {
                var requested=pendingOpenRefId
                var keep=hits.findIndex(function(h){return h.id===(requested||priorId)})
                results.currentIndex=keep>=0?keep:(hits.length?0:-1)
                if(requested){pendingOpenRefId="";selected=null;expanded=keep>=0;overviewVisible=false}
                else if (expanded && keep<0) { selected=null; expanded=false; overviewVisible=false }
            }
            error = requested && keep<0 ? "The PDF reference could not be shown in this search." : ""
            responseMs = Date.now() - searchedAt
            paintStartedAt = lastInputAt || searchedAt
            paintPending = true
            candidatesLimited = r.candidate_limited || false
            if (expanded && hits.length) showDetail()
        })
    }
    function currentHit() { return hits.length ? hits[results.currentIndex >= 0 && results.currentIndex < hits.length ? results.currentIndex : 0] : null }
    function navigate(delta) {
        if (!hits.length) return
        results.currentIndex = Math.max(0, Math.min(hits.length-1, results.currentIndex+delta))
        results.positionViewAtIndex(results.currentIndex, ListView.Contain)
        if (expanded) showDetail()
    }
    function showDetail() {
        var hit = currentHit()
        if (!hit) return
        expanded = true
        var requestedId = hit.id
        if(!selected || selected.id!==requestedId)overviewVisible=false
        var requestedProjectId = projectId
        rpc("get_reference", {id:hit.id,project_id:projectId||null,include_notes:true,include_attachments:true,include_other_projects:otherNotes.checked,note_chars:65536}, function(r) {
            if (projectId===requestedProjectId && currentHit() && currentHit().id===requestedId) selected = r
        })
    }
    function copy(text) {
        Quickshell.clipboardText = text
        notice = "Copied"
        noticeTimer.restart()
    }
    function copyKey() { var hit=currentHit(); if (hit) { copy(hit.citekey); dismiss() } }
    function copyFormat(format) {
        var hit=currentHit();if(!hit)return
        if(format==="latex")copy("\\cite{"+hit.citekey+"}")
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
    function edit(kind, n) {
        editToken = "ui-"+Date.now()+"-"+Math.random().toString(36).slice(2)
        editKind = kind
        editingNote = n || null
        discardClip(clipPath);clipPath="";clipRectangle=null
        if(kind==="note") { noteTargetId=selected?selected.id:""; noteTargetTitle=selected?selected.title:"" }
        editorDialog.title = kind==="note" ? (n ? "Edit contextual note" : "New contextual note") : kind==="metadata" ? "Edit BibTeX" : kind==="import" ? "Import BibTeX" : kind==="quick" ? "Add: DOI, arXiv ID, URL or BibTeX" : kind==="doi" ? "Add DOI" : kind==="project" ? "Create project" : "Link existing file"
        editor.text = kind==="note" ? (n ? n.body : "") : kind==="metadata" && selected ? selected.bibtex : kind==="import" ? "@article{key,\n  title = {},\n  author = {},\n  year = {}\n}" : ""
        labels.text = n ? (n.labels || []).join(", ") : ""
        evidence.text = n ? (n.evidence || "") : ""
        noteScope.currentIndex = 0
        var pid = n ? n.project_id : projectId
        for(var i=0;i<projects.length;++i) if(projects[i].id===pid)noteScope.currentIndex=i+1
        editorDialog.open()
        Qt.callLater(function(){editor.forceActiveFocus()})
    }
    function saveEditor() {
        var body=editor.text
        if ((!body.trim() && !clipPath && !(editingNote && editingNote.image)) || noteSaving || captureBusy) return
        var wasQuick=quickNoteMode
        var method, args
        if (editKind==="note") {
            if (!noteTargetId) return
            method = editingNote ? "update_note" : clipPath ? "add_visual_note" : "add_note"
            args={ref_id:noteTargetId,project_id:noteScope.currentIndex===0 ? null : projects[noteScope.currentIndex-1].id,body:body,provenance:"human",labels:labels.text.split(",").map(function(s){return s.trim()}).filter(function(s){return s.length>0}),evidence:evidence.text}
            if(clipPath){args.image_path=clipPath;args.source_pdf=quickNoteContext.pdf_path;args.page=quickNoteContext.page;args.rectangle=clipRectangle}
            if(editingNote){args.id=editingNote.id;args.expected_revision=editingNote.revision}
        } else if(editKind==="metadata") {
            method="upsert_reference";args={id:selected.id,expected_revision:selected.revision,bibtex:body}
        } else if(editKind==="import") {method="import_bibtex";args={bibtex:body,source:"Omabib UI"}}
        else if(editKind==="quick") {
            rpc("preview_entry",{input:body},function(r){pendingImport=r;previewBody.text=root.quickAddPreviewText(r);editorDialog.close();previewDialog.open()});return
        }
        else if(editKind==="doi") {
            rpc("preview_doi",{doi:body.trim()},function(r){pendingImport=r;previewBody.text=r.bibtex+(r.conflicts&&r.conflicts.length?"\n\nExisting values will be preserved. Conflicts:\n"+JSON.stringify(r.conflicts,null,2):"");editorDialog.close();previewDialog.open()});return
        } else if(editKind==="project") {method="create_project";args={name:body.trim()}}
        else {if(!selected)return;method="attach";args={ref_id:selected.id,path:body.trim(),file_type:"pdf"}}
        args.idempotency_key=editToken
        noteSaving=editKind==="note"
        var submittedToken=editToken
        noteSaveRequest=rpc(method,args,function(r){if(editToken!==submittedToken)return;editorDialog.close();if(wasQuick)return;notice="Saved";noticeTimer.restart();refresh();if(expanded)showDetail();showImportReport(r)})
        if(noteSaveRequest<0)noteSaving=false
    }
    function showImportReport(r) {
        if(r.duplicates_merged || (r.repairs||[]).length) {
            notice="Imported "+(r.items||[]).length+" unique references · merged "+(r.duplicates_merged||0)+" duplicates · "+(r.repairs||[]).length+" repairs"
            noticeTimer.restart()
        }
        var renamed=(r.items||[]).filter(function(i){return i.original_key && i.original_key!==i.citekey})
        if ((r.conflicts||[]).length || renamed.length) {
            pendingImport=null
            previewBody.text="Existing values were preserved. Resolve field conflicts with Edit BibTeX.\n\n"+JSON.stringify({conflicts:r.conflicts||[],repairs:r.repairs||[],duplicates_merged:r.duplicates_merged||0,renamed_keys:renamed.map(function(i){return {original:i.original_key,assigned:i.citekey}})},null,2)
            previewDialog.open()
        }
    }
    function syncHistory() {
        if(syncBusy)return
        if(!repoSettings.configured){openRepoSettings();return}
        syncBusy=true
        syncRequest=rpc("sync_repo",{push:true},function(r){
            syncBusy=false
            notice=r.ok===false?("Saved locally, but the push failed: "+(r.push_error||"")):"History synced · "+r.references+" references"
            noticeTimer.restart()
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
    function repoCheckSummary() {
        var c=root.repoCheck
        if(c===undefined||c.git===undefined)return "Checking…"
        var bits=[]
        bits.push(c.git?"git ✓":"git ✗ missing")
        bits.push(c.git_lfs?"git-lfs ✓":"git-lfs ✗ missing")
        bits.push(c.gh_logged_in?("gh ✓ ("+(c.gh_user||"logged in")+")"):(c.gh?"gh: not logged in — run gh auth login":"gh ✗ missing"))
        if(c.path&&c.path.state==="repo")bits.push("path: existing repo"+(c.path.lfs_tracked?", LFS tracked":", LFS NOT tracked")+(c.path.dirty?", has local edits":""))
        else if(c.path&&c.path.state&&c.path.state!=="unspecified")bits.push("path: "+c.path.state.replace(/_/g," "))
        return bits.join("   ·   ")
    }
    function createGithubRepo() {
        if(!repoNewName.text.trim()){root.error="Name the new repository first";return}
        var args={mode:"create_github",name:repoNewName.text.trim(),branch:repoBranch.text||"main"}
        if(repoPath.text)args.repo_path=repoPath.text
        root.repoBusy=true
        root.rpc("repo_setup",args,function(r){root.repoBusy=false;root.repoSettings=r;repoDialog.close();root.notice="Created and configured "+repoNewName.text.trim();noticeTimer.restart();root.checkRepoPrereqs()})
    }
    function useLocalRepo() {
        root.repoBusy=true
        root.rpc("repo_setup",{mode:"local",repo_path:repoPath.text,remote_url:repoRemote.text,branch:repoBranch.text||"main",fix_lfs:true},function(r){root.repoBusy=false;root.repoSettings=r;repoDialog.close();root.notice="Repository settings saved";noticeTimer.restart()})
    }
    function choosePdf() {
        var hit=currentHit();if(!hit)return
        attachmentRefId=hit.id;pickerKind="pdf";bibFileDialog.open()
    }
    function acceptFile(url) {
        if(pickerKind!=="pdf"){importBibFile(url);return}
        rpc("add_pdf",{ref_id:attachmentRefId,path:decodeURIComponent(url.slice(7))},function(r){notice="PDF attached";noticeTimer.restart();showDetail()})
    }
    readonly property int actionCount: 23
    function actionDigit(digit) {
        actionTimer.stop()
        var number=Number(actionDigits+digit)
        if (actionDigits==="" && Number(digit)*10<=root.actionCount) {actionDigits=digit;actionTimer.restart();return}
        actionDigits=""
        if(number>=1 && number<=root.actionCount)runAction(number)
    }
    function runAction(number) {
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
        case 15:projectDialog.open();break
        case 16:edit("project");break
        case 17:if(projectId)rpc("export_bibtex",{project_id:projectId},function(r){copy(r.bibtex)});else{notice="Choose a project first";noticeTimer.restart()}break
        case 18:if(projectId)rpc("export_notes",{project_id:projectId},function(r){copy(r.markdown)});else{notice="Choose a project first";noticeTimer.restart()}break
        case 19:syncHistory();break
        case 20:openRepoSettings();break
        case 21:requestDelete();break
        case 22:openCodex();break
        case 23:openCodex(true);break
        }
    }
    // After adding, replace whatever search/display was up with the newly
    // added reference itself, expanded — it's what the user just asked for.
    function focusOnReference(citekey) {
        if(!citekey)return
        expanded=true
        authorFilter.text="";yearFilter.text="";typeFilter.text="";labelFilter.text=""
        query.text=citekey
        query.forceActiveFocus();query.selectAll()
    }
    function importPreview() {
        if(!pendingImport)return
        var items=pendingImport.items||[]
        if(items.length===1 && items[0].recognized!=="bibtex") {
            var item=items[0]
            rpc("add_reference",{input:item.input,download_pdf:true,project_id:projectId||null,idempotency_key:editToken+"-add"},function(r){
                previewDialog.close();refresh()
                root.focusOnReference(r.citekey)
                notice="Added "+r.citekey+(r.merged?" (filled an existing reference)":"")+(r.attachment&&r.attachment.exists?" · PDF attached":"")+(r.abstract_source?" · abstract via "+r.abstract_source:"")
                noticeTimer.restart()
            })
            return
        }
        rpc("import_bibtex",pendingImport,function(r){
            previewDialog.close();refresh()
            var first=(r.items||[])[0]
            if(first)root.focusOnReference(first.citekey)
            notice="Imported";noticeTimer.restart();showImportReport(r)
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
            root.rpc("import_bibtex",{bibtex:text(),source:root.importPath,idempotency_key:"file-"+Date.now()+"-"+Math.random().toString(36).slice(2)},function(r){root.notice="Imported "+r.items.length+" references";noticeTimer.restart();root.refresh();root.showImportReport(r)})
        }
        onLoadFailed:error=>{root.importingFile=false;root.error="Could not read BibTeX file: "+root.importPath}
    }
    function chooseProject(index) {
        if(index<0 || index>projects.length)return
        projectId = index===0 ? "" : projects[index-1].id
        updateProjectName(); search(false)
        Qt.callLater(function(){query.forceActiveFocus()})
    }
    function detailThenEdit(kind) {
        var hit=currentHit();if(!hit)return
        rpc("get_reference",{id:hit.id,project_id:projectId||null,include_notes:true,include_attachments:true},function(r){selected=r;expanded=true;edit(kind,null)})
    }
    function assign() {
        var hit=currentHit()
        if(!hit || !projects.length)return
        assignTargetId=hit.id
        projectDialog.open()
    }
    function requestDelete() {
        var hit=currentHit()
        if(!hit || deleteBusy)return
        var id=hit.id
        error=""
        rpc("delete_reference_preview",{id:id},function(r){
            if(!currentHit() || currentHit().id!==id)return
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
            if(readingContext && readingContext.ref_id===target.id)readingContext=null
            if(overviewRefId===target.id){overviewRefId="";overviewBody="";overviewUrl="";overviewVisible=false}
            selected=null;expanded=false
            if(query.text.trim()===target.citekey)query.text=""
            notice="Deleted "+r.citekey+" · PDF files kept";noticeTimer.restart()
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
            notice="Note deleted";noticeTimer.restart()
            refresh();showDetail()
        })
        if(noteDeleteRequest<0)noteDeleteBusy=false
    }
    function assignToProject(index) {
        if(index<0 || index>=projects.length || !assignTargetId)return
        var refId=assignTargetId, target=projects[index]
        assignTargetId=""
        projectDialog.close()
        rpc("associate",{ref_id:refId,project_id:target.id,labels:[],idempotency_key:"ui-associate-"+Date.now()+"-"+Math.random().toString(36).slice(2)},function(){notice="Assigned to "+target.name;noticeTimer.restart();search(false)})
    }
    IpcHandler {
        target: "omabib"
        function setQuery(text: string): void { query.text = text }
        function selectProject(index: int): void { root.chooseProject(index) }
        function openAssign(): void { root.assign() }
        function openCodex(): void { root.openCodex() }
        function openChatGPT(): void { root.openCodex(true) }
        function openDelete(): void { root.requestDelete() }
        function openNoteDelete(id: string): void { root.requestNoteDelete(id) }
        function loadOverview(): void { root.showAlphaXivOverview() }
        function state(): string { return JSON.stringify({opened:root.opened,reading_context:root.readingContext,quick_note:root.quickNoteMode,note_target_id:root.noteTargetId,note_evidence:evidence.text,clip_path:root.clipPath,capture_busy:root.captureBusy,note_scope:noteScope.currentIndex,editor_focused:editor.activeFocus,expanded:root.expanded,query:query.text,project_id:root.projectId,project_name:root.projectName,project_select_index:projectSelect.currentIndex,assign_open:projectDialog.opened,delete_open:deleteDialog.opened,delete_preview:root.deletePreview?root.deletePreview.citekey:null,note_delete_open:noteDeleteDialog.opened,note_delete_preview:root.noteDeletePreview?root.noteDeletePreview.id:null,assign_enabled:root.selected!==null&&root.projects.length>0,overview_visible:root.overviewVisible,overview_busy:root.overviewBusy,overview_ref_id:root.overviewRefId,overview_chars:root.overviewBody.length,browse_sort:root.browseSort,results:root.hits.map(function(h){return h.citekey}),result_index:results.currentIndex,selected:root.selected?root.selected.id:null,error:root.error,editor_open:editorDialog.opened,commands_open:commandDialog.opened,file_picker_open:bibFileDialog.visible,action_digits:root.actionDigits,repo_open:repoDialog.opened,metadata_open:metadataDialog.opened,import_preview_open:previewDialog.opened,metadata_busy:root.metadataBusy,metadata_candidates:root.metadataLookup?root.metadataLookup.candidates.length:0,pdf_busy:root.pdfBusy,sync_busy:root.syncBusy,picker_kind:root.pickerKind,picker_path:filePath.text,picker_matches:bibFileDialog.matches.map(function(m){return m.name}),picker_index:fileList.currentIndex,picker_focused:filePath.activeFocus,picker_chosen:bibFileDialog.lastChosen,edit_kind:root.editKind,query_focused:query.activeFocus,response_ms:root.responseMs,paint_ms:root.lastPaintMs,open_ms:root.openMs,search_pending:root.searchPending,paint_pending:root.paintPending,open_pending:root.openPending}) }
    }
    Timer { id: noticeTimer; interval: 2500; onTriggered: root.notice="" }
    Timer { id: debounce; interval: 12; onTriggered: root.search(false) }
    Timer { interval: 1500; running: !socket.connected; repeat: true; onTriggered: socket.connected=true }
    Socket {
        id: socket
        path: root.serviceSocket
        connected: true
        onConnectedChanged: {
            if(connected){root.error="";if(root.pendingQuickNote){var p=root.pendingQuickNote;root.pendingQuickNote=null;root.openQuickNote(p)}else if(root.opened)root.refresh()}
            else {root.pending=({});root.noteSaving=false;root.metadataBusy=false;root.syncBusy=false;root.pdfBusy=false;root.error="Library service disconnected. Reconnecting…"}
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
    PanelWindow {
        id: window
        visible: root.opened && !root.captureBusy
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omabib"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        MouseArea { anchors.fill:parent;onClicked:root.dismiss() }
        Label {anchors.centerIn:parent;visible:root.quickNoteMode&&!editorDialog.opened;text:root.error||"Opening note…";color:root.fg;wrapMode:Text.Wrap;width:Math.min(600,parent.width-60)}
        Rectangle {
            id: card
            visible: !root.quickNoteMode
            anchors.centerIn: parent
            width: Math.min(parent.width-48,root.expanded?1100:760)
            height: Math.min(parent.height-64,root.expanded?800:550)
            color: root.bg
            radius: Style.cornerRadius
            border.color: root.borderColor
            border.width: 1
            MouseArea { anchors.fill:parent;onClicked:query.forceActiveFocus() }
            ColumnLayout {
                anchors.fill:parent;anchors.margins:22;spacing:12
                RowLayout {
                    Layout.fillWidth:true
                    Label { text:"omabib";color:root.fg;font.family:root.fontFamily;font.pixelSize:22;font.bold:true }
                    Label { text:root.referenceCount.toLocaleString()+" references";color:root.fg;opacity:.755;font.pixelSize:12;Layout.fillWidth:true }
                    ComboBox {
                        id:projectSelect
                        objectName:"projectSelect"
                        Layout.preferredWidth:Math.min(190,Math.max(140,implicitWidth))
                        model:["All references"].concat(root.projects.map(function(p){return p.name}))
                        currentIndex:{for(var i=0;i<root.projects.length;i++)if(root.projects[i].id===root.projectId)return i+1;return 0}
                        onActivated:index=>root.chooseProject(index)
                        palette.window:root.bg
                        palette.windowText:root.fg
                        palette.button:root.bg
                        palette.buttonText:root.fg
                        background:Rectangle{color:root.bg;border.color:root.borderColor;border.width:1;radius:Style.cornerRadius}
                    }
                    BibButton {text:root.syncChipText();enabled:!root.syncBusy;onClicked:root.syncHistory()}
                    BibButton {text:"Repo";onClicked:root.openRepoSettings()}
                    BibButton { text:"⌘  Actions";onClicked:commandDialog.open() }
                }
                TextField {
                    id:query;objectName:"searchField";Layout.fillWidth:true;placeholderText:"Search title, author, abstract, or notes…";font.pixelSize:20;font.family:root.fontFamily;color:root.fg;selectByMouse:true
                    background:Rectangle{color:"transparent";radius:5;border.width:query.activeFocus?2:1;border.color:root.borderColor}
                    onTextChanged:{++root.searchSequence;root.searchPending=true;root.lastInputAt=Date.now();debounce.restart()}
                    Keys.onShortcutOverride:event=>{
                        if((event.modifiers & Qt.ControlModifier) && (event.key===Qt.Key_U || event.key===Qt.Key_O))event.accepted=true
                        else if(event.key===Qt.Key_Q && event.modifiers===Qt.NoModifier && query.text.trim()==="")event.accepted=true
                    }
                    Keys.onPressed:event=>{
                        if(event.key===Qt.Key_Q && event.modifiers===Qt.NoModifier && query.text.trim()===""){root.dismiss();event.accepted=true}
                        else if(event.key===Qt.Key_U && event.modifiers & Qt.ControlModifier){root.openLink();event.accepted=true}
                        else if(event.key===Qt.Key_O && event.modifiers & Qt.ControlModifier){root.getPdf();event.accepted=true}
                        else if(event.key===Qt.Key_Down || (event.key===Qt.Key_N && event.modifiers & Qt.ControlModifier)){root.navigate(1);event.accepted=true}
                        else if(event.key===Qt.Key_Up || (event.key===Qt.Key_P && event.modifiers & Qt.ControlModifier)){root.navigate(-1);event.accepted=true}
                        else if(event.key===Qt.Key_Return || event.key===Qt.Key_Enter){
                            if(root.hits.length===0 && root.looksLikeIdentifier(query.text)){var pasted=query.text.trim();root.edit("quick");editor.text=pasted}
                            else root.openPdf()
                            event.accepted=true
                        }
                        else if(event.key===Qt.Key_Tab){root.showDetail();event.accepted=true}
                    }
                }
                RowLayout {
                    Layout.fillWidth:true
                    BibButton {text:filters.visible?"Hide filters":"Filters";onClicked:filters.visible=!filters.visible}
                    BibButton {objectName:"sortButton";text:query.text.trim()!==""?"Sort: relevance":(root.browseSort==="added_desc"?"Sort: newest added ↓":"Sort: citation key A–Z");enabled:query.text.trim()==="";onClicked:root.toggleBrowseSort()}
                    CheckBox {text:"Search other projects’ notes";checked:root.allNotes;onToggled:{root.allNotes=checked;root.search(false)}}
                    Item {Layout.fillWidth:true}
                    Label {text:root.notice;color:root.fg;font.pixelSize:12}
                }
                RowLayout {
                    id:filters;visible:false;Layout.fillWidth:true
                    TextField{id:authorFilter;placeholderText:"Author";Layout.fillWidth:true;onTextChanged:{++root.searchSequence;root.searchPending=true;root.lastInputAt=Date.now();debounce.restart()}}
                    TextField{id:yearFilter;placeholderText:"Year";Layout.preferredWidth:72;onTextChanged:{++root.searchSequence;root.searchPending=true;root.lastInputAt=Date.now();debounce.restart()}}
                    TextField{id:typeFilter;placeholderText:"Type: article";Layout.preferredWidth:110;onTextChanged:{++root.searchSequence;root.searchPending=true;root.lastInputAt=Date.now();debounce.restart()}}
                    TextField{id:labelFilter;placeholderText:"Label";Layout.preferredWidth:90;onTextChanged:{++root.searchSequence;root.searchPending=true;root.lastInputAt=Date.now();debounce.restart()}}
                }
                Label {visible:root.candidatesLimited;text:"Showing the strongest matches from a bounded candidate set. Add a word to narrow your search.";color:root.fg;opacity:.75;wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:11}
                Label {visible:root.error!=="";text:root.error;color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:13}
                RowLayout {
                    Layout.fillWidth:true;Layout.fillHeight:true;spacing:20
                    ColumnLayout {
                        Layout.fillHeight:true;Layout.fillWidth:true;Layout.preferredWidth:root.expanded?380:700
                        ListView {
                            id:results;objectName:"results";Layout.fillWidth:true;Layout.fillHeight:true;clip:true;model:root.hits;spacing:4;currentIndex:-1;reuseItems:true
                            onCountChanged:if(count>0 && currentIndex<0)currentIndex=0
                            ScrollBar.vertical:ScrollBar{}
                            delegate:ItemDelegate {
                                required property var modelData
                                required property int index
                                width:results.width;height:92
                                highlighted:results.currentIndex===index
                                background:Rectangle{radius:5;color:results.currentIndex===index?root.selectedBg:"transparent"}
                                contentItem:Column {
                                    spacing:4
                                    Label {width:parent.width;text:modelData.title||modelData.citekey;elide:Text.ElideRight;maximumLineCount:2;wrapMode:Text.Wrap;color:results.currentIndex===index?root.selectedFg:root.fg;font.pixelSize:15;font.bold:true;textFormat:Text.PlainText}
                                    Label {width:parent.width;text:modelData.authors+" · "+modelData.year;elide:Text.ElideRight;color:results.currentIndex===index?root.selectedFg:root.fg;opacity:.7;font.pixelSize:12;textFormat:Text.PlainText}
                                    Label {width:parent.width;text:modelData.citekey+"  ·  "+(modelData.created_at?"added "+root.relativeTime(modelData.created_at):modelData.match_type)+(modelData.note_count?"  ·  "+modelData.note_count+" notes":"");elide:Text.ElideRight;color:results.currentIndex===index?root.selectedFg:root.fg;opacity:.8;font.pixelSize:11;textFormat:Text.PlainText}
                                }
                                onClicked:{results.currentIndex=index;root.showDetail();query.forceActiveFocus()}
                            }
                            Label {anchors.centerIn:parent;visible:root.hits.length===0;text:root.looksLikeIdentifier(query.text)?"Press Enter to add "+query.text.trim()+" to your library":(root.referenceCount?"No matching references":"Your library is ready.\nAdd BibTeX or a DOI from Actions.");horizontalAlignment:Text.AlignHCenter;color:root.fg;opacity:.8}
                        }
                        BibButton {visible:root.nextCursor!==null;text:"More results";Layout.alignment:Qt.AlignHCenter;onClicked:root.search(true)}
                    }
                    Rectangle {visible:root.expanded;Layout.fillHeight:true;width:1;color:root.borderColor}
                    ScrollView {
                        id:detail;visible:root.expanded;Layout.fillHeight:true;Layout.fillWidth:true;Layout.preferredWidth:650;clip:true
                        ColumnLayout {
                            width:detail.availableWidth;spacing:12
                            Label {text:root.selected?root.selected.title:"";font.pixelSize:23;font.bold:true;color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                            Label {text:root.selected?root.selected.authors+" · "+root.selected.year:"";color:root.fg;opacity:.7;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                            RowLayout {
                                BibButton{text:"Attach PDF";onClicked:root.choosePdf()}
                                BibButton{text:"New note";onClicked:root.edit("note",null)}
                                BibButton{text:"Assign to project";enabled:root.selected!==null&&root.projects.length>0;onClicked:root.assign()}
                                BibButton{text:"Edit BibTeX";onClicked:root.edit("metadata",null)}
                            }
                            RowLayout {
                                BibButton{text:"Open link";onClicked:root.openLink()}
                                BibButton{text:root.pdfBusy?"Opening PDF…":"Open PDF";enabled:!root.pdfBusy;onClicked:root.getPdf()}
                                BibButton{text:"Copy PDF path";onClicked:root.copyPdfPath()}
                                BibButton{text:root.codexBusy?"Opening Codex…":"Codex";enabled:root.selected!==null&&!root.codexBusy;onClicked:root.openCodex()}
                            }
                            RowLayout {
                                BibButton{text:"ChatGPT";enabled:root.selected!==null&&!root.codexBusy;onClicked:root.openCodex(true)}
                            }
                            RowLayout {
                                BibButton{text:root.metadataBusy?"Looking up…":"Fill metadata";enabled:!root.metadataBusy;onClicked:root.lookupMetadata()}
                                BibButton{visible:root.selected&&root.arxivIdOf(root.selected)!=="";text:root.overviewBusy?"Loading AlphaXiv…":root.overviewVisible?"Hide AI Overview":"AlphaXiv AI Overview";enabled:!root.overviewBusy;onClicked:root.showAlphaXivOverview()}
                                BibButton{text:"Delete item…";enabled:root.selected!==null;onClicked:root.requestDelete()}
                            }
                            ColumnLayout {
                                visible:root.overviewVisible&&root.selected&&root.overviewRefId===root.selected.id
                                Layout.fillWidth:true;spacing:6
                                RowLayout {Layout.fillWidth:true
                                    Label{text:"AlphaXiv AI Overview";color:root.fg;font.bold:true;Layout.fillWidth:true}
                                    BibButton{text:"Open source";onClicked:root.openAlphaXiv()}
                                }
                                Label{text:"AI-generated source summary · cached locally";color:root.fg;opacity:.65;font.pixelSize:11}
                                TextEdit {
                                    id: overviewMarkdown
                                    objectName: "overviewMarkdown"
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: contentHeight
                                    text: root.overviewBody
                                    textFormat: TextEdit.MarkdownText
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: TextEdit.Wrap
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: 13
                                    onLinkActivated: url => root.openExternal(url)
                                }
                            }
                            Label {text:root.selected?(root.selected.abstract||"No abstract available."):"";color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:14;textFormat:Text.PlainText}
                            Repeater {
                                model:root.selected?(root.selected.attachments||[]):[]
                                RowLayout {
                                    required property var modelData
                                    Layout.fillWidth:true
                                    BibButton{text:(modelData.exists?"Open PDF: ":"Missing: ")+modelData.path.split("/").pop();enabled:modelData.exists;Layout.fillWidth:true;onClicked:root.openExternal(root.fileUrl(modelData.path))}
                                    BibButton{text:"Pull";visible:!modelData.exists;onClicked:root.rpc("pull_pdf",{attachment_id:modelData.id},function(){root.notice="PDF restored";noticeTimer.restart();root.showDetail()})}
                                    BibButton{text:"Remove link";onClicked:root.rpc("remove_pdf",{attachment_id:modelData.id},function(){root.notice="Attachment removed; file kept";noticeTimer.restart();root.showDetail()})}
                                }
                            }
                            Label {text:"Contextual notes";color:root.fg;font.pixelSize:17;font.bold:true}
                            CheckBox{id:otherNotes;text:"Other projects’ notes"+(root.selected?" ("+root.selected.other_project_note_count+")":"");onToggled:root.showDetail()}
                            Repeater {
                                model:root.selected?(root.selected.notes||[]):[]
                                Rectangle {
                                    required property var modelData
                                    Layout.fillWidth:true;implicitHeight:noteColumn.implicitHeight+24;color:"transparent";radius:5;border.color:root.borderColor
                                    ColumnLayout {
                                        id:noteColumn;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;anchors.margins:12;spacing:8
                                        RowLayout {Layout.fillWidth:true;Label{text:modelData.project_name||"Global";color:root.fg;font.bold:true;Layout.fillWidth:true}BibButton{text:"Edit";onClicked:root.edit("note",modelData)}BibButton{text:"Delete…";onClicked:root.requestNoteDelete(modelData.id)}}
                                        Label {text:modelData.body;color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                                        Label {text:(modelData.labels||[]).join(" · ")+(modelData.evidence?" · "+modelData.evidence:"");color:root.fg;opacity:.8;font.pixelSize:11;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                                        BibButton {visible:!!modelData.image;text:savedClip.source.toString()?"Hide clip":"Show image clip · PDF p. "+(modelData.image?modelData.image.page:"");onClicked:{if(savedClip.source.toString()){savedClip.source="";return}root.rpc("get_note_image",{note_id:modelData.id,project_id:modelData.project_id},function(r){savedClip.source="data:image/png;base64,"+r.data})}}
                                        Image {id:savedClip;visible:source.toString()!=="";Layout.fillWidth:true;Layout.preferredHeight:220;fillMode:Image.PreserveAspectFit}
                                        Label {text:modelData.provenance+" · revision "+modelData.revision;color:root.fg;opacity:.75;font.pixelSize:11;textFormat:Text.PlainText}
                                    }
                                }
                            }
                            BibButton {visible:root.selected && root.selected.next_note_cursor!==null && root.selected.next_note_cursor!==undefined;text:"Load more notes";onClicked:root.rpc("get_reference",{id:root.selected.id,project_id:root.projectId||null,include_notes:true,include_other_projects:otherNotes.checked,note_cursor:root.selected.next_note_cursor,note_chars:65536},function(r){var v=Object.assign({},root.selected);v.notes=v.notes.concat(r.notes);v.next_note_cursor=r.next_note_cursor;root.selected=v})}
                            Item {height:12}
                        }
                    }
                }
                RowLayout {Layout.fillWidth:true;Label{text:"↑↓ navigate   Enter open   "+root.pdfShortcut+" PDF   Ctrl+U link   Ctrl+S sort   Tab details   Ctrl+K actions   Q/Esc close";color:root.fg;opacity:.75;font.pixelSize:11;Layout.fillWidth:true}BibButton{visible:root.expanded;text:"Compact";onClicked:{root.expanded=false;query.forceActiveFocus()}}}
            }
        }
        Shortcut {sequence:root.pdfShortcut;enabled:root.opened&&!editorDialog.opened;onActivated:root.getPdf()}
        Shortcut {sequence:"Ctrl+U";enabled:root.opened&&!editorDialog.opened;onActivated:root.openLink()}
        Shortcut {sequence:"Ctrl+S";enabled:root.opened&&!editorDialog.opened&&!commandDialog.opened&&!projectDialog.opened&&!previewDialog.opened&&!bibFileDialog.opened&&!repoDialog.opened&&!metadataDialog.opened;onActivated:root.toggleBrowseSort()}
        Shortcut {sequence:"Ctrl+K";enabled:root.opened&&!editorDialog.opened;onActivated:commandDialog.open()}
        Shortcut {sequence:"Ctrl+P";enabled:root.opened&&!editorDialog.opened;onActivated:projectSelect.popup.open()}
        Shortcut {sequence:"Escape";enabled:root.opened&&!editorDialog.opened&&!commandDialog.opened&&!projectDialog.opened&&!previewDialog.opened&&!bibFileDialog.opened&&!repoDialog.opened&&!metadataDialog.opened&&!deleteDialog.opened&&!noteDeleteDialog.opened;onActivated:root.dismiss()}
        Shortcut {sequence:"Q";enabled:root.opened&&query.text.trim()===""&&!editorDialog.opened&&!commandDialog.opened&&!projectDialog.opened&&!previewDialog.opened&&!bibFileDialog.opened&&!repoDialog.opened&&!metadataDialog.opened&&!deleteDialog.opened&&!noteDeleteDialog.opened;onActivated:root.dismiss()}
        BibDialog {
            id:commandDialog;title:"Actions";anchors.centerIn:parent;width:480;height:Math.min(window.height-50,630);modal:true;closePolicy:Popup.CloseOnEscape|Popup.CloseOnPressOutside
            onOpened:root.actionDigits=""
            onClosed:{root.actionDigits="";actionTimer.stop()}
            ColumnLayout {
                anchors.fill:parent
                Label {text:root.actionDigits ? "Number: "+root.actionDigits+" · Enter to select" : "Type 1–23 to select an action";color:root.fg;Layout.fillWidth:true}
                ScrollView {
                    id:actionsScroll
                    Layout.fillWidth:true;Layout.fillHeight:true
                    ColumnLayout {
                        width:actionsScroll.availableWidth
                        Repeater {
                            model:["Add new item (DOI / arXiv / URL / BibTeX)","Copy citation key","Copy LaTeX citation","Copy Pandoc / Quarto citation","Copy BibTeX","Paste BibTeX","Import BibTeX file…","Add DOI","New contextual note","Attach PDF","Open link","Open PDF (download if needed)","Copy PDF path","Fill metadata online","Choose project","Create project","Copy project bibliography","Copy project notes","Sync history","Repository settings","Delete current item…","Chat about item in Codex","Chat about item in ChatGPT Desktop"]
                            BibButton {
                                required property string modelData
                                required property int index
                                text:(index+1)+"  "+modelData;Layout.fillWidth:true
                                onClicked:root.runAction(index+1)
                            }
                        }
                    }
                }
            }
            Repeater {
                model:10
                Item {
                    required property int index
                    Shortcut {sequence:String(index);enabled:commandDialog.opened;onActivated:root.actionDigit(String(index))}
                }
            }
            Shortcut {sequence:"Return";enabled:commandDialog.opened && root.actionDigits!=="";onActivated:root.runAction(Number(root.actionDigits))}
            Shortcut {sequence:"Backspace";enabled:commandDialog.opened;onActivated:{root.actionDigits="";actionTimer.stop()}}
        }
        BibDialog {
            id:deleteDialog;title:"Delete reference";anchors.centerIn:parent;width:Math.min(460,window.width-60);height:270;modal:true;closePolicy:Popup.CloseOnEscape
            onClosed:{if(!root.deleteBusy)root.deletePreview=null}
            ColumnLayout {
                anchors.fill:parent;spacing:12
                Label {text:root.deletePreview ? root.deletePreview.title+" ["+root.deletePreview.citekey+"]" : "";color:root.fg;font.bold:true;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                Label {text:root.deletePreview ? "Delete this reference, "+root.deletePreview.note_count+" note(s), "+root.deletePreview.attachment_count+" attachment link(s), "+root.deletePreview.project_count+" project link(s), and "+root.deletePreview.summary_count+" cached summary?" : "";color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                Label {text:"PDF files stay on disk. There is no in-app undo. Ctrl+Enter deletes.";color:root.fg;opacity:.75;wrapMode:Text.Wrap;Layout.fillWidth:true}
                Label {visible:root.error!=="";text:root.error;color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true}
                Item {Layout.fillHeight:true}
                RowLayout {Layout.alignment:Qt.AlignRight;BibButton{text:"Cancel";enabled:!root.deleteBusy;onClicked:deleteDialog.close()}BibButton{text:root.deleteBusy?"Deleting…":"Delete item";enabled:!root.deleteBusy;onClicked:root.confirmDelete()}}
            }
            Shortcut {sequence:"Ctrl+Return";enabled:deleteDialog.opened&&!root.deleteBusy;onActivated:root.confirmDelete()}
        }
        BibDialog {
            id:noteDeleteDialog;title:"Delete note";anchors.centerIn:parent;width:Math.min(460,window.width-60);height:245;modal:true;closePolicy:Popup.CloseOnEscape
            onClosed:{if(!root.noteDeleteBusy)root.noteDeletePreview=null}
            ColumnLayout {
                anchors.fill:parent;spacing:12
                Label {text:root.noteDeletePreview ? root.noteDeletePreview.project_name+" note on ["+root.noteDeletePreview.citekey+"]" : "";color:root.fg;font.bold:true;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                Label {text:root.noteDeletePreview ? (root.noteDeletePreview.excerpt||"Image-only note") : "";color:root.fg;wrapMode:Text.Wrap;elide:Text.ElideRight;maximumLineCount:3;Layout.fillWidth:true;textFormat:Text.PlainText}
                Label {text:root.noteDeletePreview&&root.noteDeletePreview.has_image ? "Its saved image clip and revisions will also be deleted." : "Its revisions will also be deleted.";color:root.fg;opacity:.75;wrapMode:Text.Wrap;Layout.fillWidth:true}
                Label {visible:root.error!=="";text:root.error;color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true}
                Item {Layout.fillHeight:true}
                RowLayout {Layout.alignment:Qt.AlignRight;BibButton{text:"Cancel";enabled:!root.noteDeleteBusy;onClicked:noteDeleteDialog.close()}BibButton{text:root.noteDeleteBusy?"Deleting…":"Delete note";enabled:!root.noteDeleteBusy;onClicked:root.confirmNoteDelete()}}
            }
            Shortcut {sequence:"Ctrl+Return";enabled:noteDeleteDialog.opened&&!root.noteDeleteBusy;onActivated:root.confirmNoteDelete()}
        }
        BibDialog {
            id:bibFileDialog
            title:root.pickerKind==="pdf"?"Attach PDF to reference":"Import BibTeX file"
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
                anchors.fill:parent
                TextField {
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
                RowLayout {
                    BibButton{text:"Up";onClicked:bibFileDialog.go(folders.parentFolder.toString())}
                    Label{text:"Type to filter · ↑↓ select · Enter open / attach · Ctrl+L path";color:root.fg;Layout.fillWidth:true;wrapMode:Text.Wrap}
                }
                Label {visible:bibFileDialog.matches.length===0;text:folders.status===FolderListModel.Loading?"Loading folder…":"No matching folders or files";color:root.fg;Layout.fillWidth:true}
                ListView {
                    id:fileList
                    Layout.fillWidth:true;Layout.fillHeight:true;clip:true
                    model:bibFileDialog.matches;currentIndex:0
                    delegate:BibButton {
                        required property int index
                        required property var modelData
                        width:ListView.view.width
                        textLeft:true
                        text:(modelData.isDir?"▸  ":"    ")+modelData.name
                        background:Rectangle{color:fileList.currentIndex===index?root.selectedBg:"transparent";radius:4}
                        onClicked:{fileList.currentIndex=index;bibFileDialog.choose(index)}
                    }
                    Keys.onReturnPressed:bibFileDialog.choose(currentIndex)
                    ScrollBar.vertical:ScrollBar{}
                }
                RowLayout {
                    Layout.alignment:Qt.AlignRight
                    BibButton{text:"Cancel";onClicked:bibFileDialog.close()}
                    BibButton{text:fileList.currentIndex>=0&&bibFileDialog.matches[fileList.currentIndex]&&!bibFileDialog.matches[fileList.currentIndex].isDir?(root.pickerKind==="pdf"?"Attach PDF":"Import file"):"Open folder";enabled:bibFileDialog.matches.length>0;onClicked:bibFileDialog.choose(fileList.currentIndex)}
                }
            }
            Shortcut {sequence:"Ctrl+L";enabled:bibFileDialog.opened;onActivated:{filePath.forceActiveFocus();filePath.selectAll()}}
            Shortcut {sequence:"Alt+Up";enabled:bibFileDialog.opened;onActivated:bibFileDialog.go(folders.parentFolder.toString())}
        }
        BibDialog {
            id:repoDialog;title:"History repository";anchors.centerIn:parent;width:Math.min(720,window.width-60);modal:true
            ColumnLayout {
                anchors.fill:parent
                Label{text:root.repoCheckSummary();color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:11;opacity:.85}
                Label{text:"Path (existing checkout, or where to create a new one)";color:root.fg}
                RowLayout{Layout.fillWidth:true;TextField{id:repoPath;Layout.fillWidth:true;placeholderText:"/absolute/path/to/history";onEditingFinished:root.checkRepoPrereqs()}BibButton{text:"Check";onClicked:root.checkRepoPrereqs()}}
                Label{text:"Branch";color:root.fg}
                TextField{id:repoBranch;Layout.fillWidth:true;text:"main"}
                Label{text:root.error;visible:text!=="";color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true}
                Rectangle{Layout.fillWidth:true;height:1;color:root.borderColor}
                Label{text:"Create a new private GitHub repository";color:root.fg;font.bold:true}
                RowLayout{Layout.fillWidth:true;TextField{id:repoNewName;Layout.fillWidth:true;placeholderText:"omabib-history"}BibButton{text:root.repoBusy?"Working…":"Create";enabled:!root.repoBusy&&root.repoCheck.gh_logged_in===true;onClicked:root.createGithubRepo()}}
                Rectangle{Layout.fillWidth:true;height:1;color:root.borderColor}
                Label{text:"Or use an existing local checkout";color:root.fg;font.bold:true}
                Label{text:"Remote URL (origin) — leave blank to keep the checkout's own";color:root.fg}
                TextField{id:repoRemote;Layout.fillWidth:true;placeholderText:"https://github.com/owner/repository.git"}
                Label{text:"Sync exports the local library and pushes it; Git LFS is configured automatically if it isn't tracking PDFs yet. Remote metadata is never merged into SQLite.";color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:11;opacity:.85}
                RowLayout {Layout.alignment:Qt.AlignRight;BibButton{text:"Cancel";onClicked:repoDialog.close()}BibButton{text:root.repoBusy?"Working…":"Use this checkout";enabled:!root.repoBusy;onClicked:root.useLocalRepo()}}
            }
        }
        BibDialog {
            id:projectDialog;title:"Assign to project";anchors.centerIn:parent;width:400;height:Math.min(window.height-60,450);modal:true
            contentItem:ListView {
                clip:true;model:root.projects;currentIndex:0
                delegate:ItemDelegate{required property var modelData;required property int index;text:modelData.name;width:ListView.view.width;highlighted:ListView.isCurrentItem;onClicked:root.assignToProject(index)}
                Keys.onReturnPressed:root.assignToProject(currentIndex)
                Component.onCompleted:forceActiveFocus()
            }
            onOpened:contentItem.forceActiveFocus()
        }
        BibDialog {
            id:editorDialog;anchors.centerIn:parent
            width:Math.min(root.quickNoteMode?440:760,window.width-60)
            height:Math.min(root.quickNoteMode?(root.clipPath?410:260):640,window.height-60)
            padding:root.quickNoteMode?16:20
            modal:true;closePolicy:Popup.CloseOnEscape
            background: Rectangle {color:Qt.rgba(root.bg.r,root.bg.g,root.bg.b,1);radius:Style.cornerRadius;border.color:root.borderColor;border.width:1}
            header: Label {text:editorDialog.title;color:root.fg;font.family:root.fontFamily;font.pixelSize:12;opacity:.65;padding:16;bottomPadding:4}
            onClosed:{if(!root.noteSaving){root.discardClip(root.clipPath);root.clipPath=""}if(root.quickNoteMode){root.quickNoteMode=false;root.dismiss()}}
            ColumnLayout {
                anchors.fill:parent
                Label {visible:root.editKind==="note";text:root.noteTargetTitle;color:root.fg;elide:Text.ElideRight;maximumLineCount:1;Layout.fillWidth:true;textFormat:Text.PlainText;font.pixelSize:13;font.bold:true}
                Label {visible:false;text:root.quickNoteContext?"PDF page "+root.quickNoteContext.page+" of "+root.quickNoteContext.total_pages+" · Ctrl+Enter saves":"";color:root.fg}
                RowLayout {
                    visible:root.quickNoteMode
                    BibButton {text:root.clipPath?"Recapture":"Add clip";enabled:!root.noteSaving&&!root.captureBusy;onClicked:root.captureClip()}
                    BibButton {visible:root.clipPath!=="";text:"Remove";enabled:!root.noteSaving;onClicked:{root.discardClip(root.clipPath);root.clipPath="";root.clipRectangle=null}}
                    Item {Layout.fillWidth:true}
                    Label {text:"Ctrl+Shift+C";color:root.fg;opacity:.4;font.pixelSize:10}
                }
                Image {visible:root.clipPath!=="";source:root.clipPath?root.fileUrl(root.clipPath):"";Layout.fillWidth:true;Layout.preferredHeight:130;fillMode:Image.PreserveAspectFit;cache:false}

                Label {visible:root.editKind==="note"&&!root.quickNoteMode;text:"Assessment scope"}
                ComboBox{id:noteScope;visible:root.editKind==="note";model:["Global · all projects"].concat(root.projects.map(function(p){return p.name}));Layout.fillWidth:true}
                ScrollView {Layout.fillWidth:true;Layout.fillHeight:true;TextArea{id:editor;objectName:"editor";wrapMode:TextEdit.Wrap;selectByMouse:true;font.family:root.fontFamily;placeholderText:root.quickNoteMode?(root.clipPath?"Add a comment…":"Write a note…"):root.editKind==="quick"?"Paste a DOI, arXiv ID, URL, several of those, or a whole BibTeX entry…":root.editKind==="doi"?"10.xxxx/…":root.editKind==="attachment"?"/absolute/path/to/paper.pdf":root.editKind==="project"?"Project name":""}}
                TextField{id:labels;visible:root.editKind==="note"&&!root.quickNoteMode;placeholderText:"Optional labels, separated by commas";Layout.fillWidth:true}
                TextField{id:evidence;visible:root.editKind==="note"&&!root.quickNoteMode;placeholderText:"Optional evidence location, e.g. PDF p. 7, Table 2";Layout.fillWidth:true}
                Label{visible:root.error!=="";text:root.error;wrapMode:Text.Wrap;Layout.fillWidth:true}
                RowLayout {Layout.fillWidth:true;Label{visible:root.quickNoteMode;text:"Esc cancel · Ctrl+Enter save";color:root.fg;opacity:.45;font.pixelSize:10;Layout.fillWidth:true}BibButton{text:"Cancel";visible:!root.quickNoteMode;onClicked:editorDialog.close()}BibButton{text:(root.editKind==="doi"||root.editKind==="quick")?"Preview":"Save";onClicked:root.saveEditor()}}
            }
            Shortcut{sequence:"Ctrl+Return";enabled:editorDialog.opened;onActivated:root.saveEditor()}
            Shortcut{sequence:"Ctrl+Shift+C";enabled:editorDialog.opened&&root.quickNoteMode;onActivated:root.captureClip()}
        }
        BibDialog {
            id:metadataDialog;title:"Fill metadata online";anchors.centerIn:parent;width:Math.min(780,window.width-60);height:Math.min(680,window.height-60);modal:true
            ColumnLayout {
                anchors.fill:parent
                Label {text:root.metadataBusy?"Looking up metadata…":root.metadataInfo;color:root.fg;wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                ComboBox {
                    id:metadataCandidates;Layout.fillWidth:true
                    model:root.metadataLookup?root.metadataLookup.candidates.map(function(c){return (c.fields.title||"Untitled")+" · "+(c.fields.year||"")+" · "+(c.fields.author||"")}):[]
                    enabled:!root.metadataBusy && count>0
                    onActivated:root.selectMetadata(currentIndex)
                }
                BibButton {text:"Review selected match";enabled:!root.metadataBusy && metadataCandidates.count>0;onClicked:root.selectMetadata(metadataCandidates.currentIndex)}
                ScrollView {
                    Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumHeight:0;clip:true
                    TextArea {readOnly:true;wrapMode:TextEdit.Wrap;selectByMouse:true;text:root.metadataPreviewText()}
                }
                RowLayout {Layout.alignment:Qt.AlignRight;BibButton{text:"Cancel";onClicked:metadataDialog.close()}BibButton{text:"Fill missing fields";enabled:root.metadataChoice!==null&&!root.metadataBusy;onClicked:root.applyMetadata()}}
            }
            Shortcut {sequence:"Ctrl+Return";enabled:metadataDialog.opened&&!root.metadataBusy&&root.metadataChoice!==null;onActivated:root.applyMetadata()}
        }
        BibDialog {
            id:previewDialog
            Shortcut {sequence:"Ctrl+Return";enabled:previewDialog.opened&&root.pendingImport!==null;onActivated:root.importPreview()}
            title:root.pendingImport?"Review reference metadata":"Import report";anchors.centerIn:parent;width:Math.min(760,window.width-60);height:Math.min(600,window.height-60);modal:true
            ColumnLayout {
                anchors.fill:parent
                ScrollView{Layout.fillWidth:true;Layout.fillHeight:true;TextArea{id:previewBody;readOnly:true;wrapMode:TextEdit.Wrap;selectByMouse:true}}
                RowLayout{Layout.alignment:Qt.AlignRight;BibButton{text:"Close";onClicked:previewDialog.close()}BibButton{visible:root.pendingImport!==null;text:"Import";onClicked:root.importPreview()}}
            }
        }
    }
}
