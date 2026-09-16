import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import qs.Ui

// A PDF reader tab. The service renders pages with MuPDF; this pane lays them
// out, selects and searches text, and turns a dragged rectangle into a clip
// note. The reference's notes, overview and AI summary sit beside the pages.
//
// Page geometry is in PDF points with a top-left origin, as the service
// reports it. On screen a point is `zoom` logical pixels; the device pixel
// ratio only changes the scale pages are rendered at.
FocusScope {
    id: root

    required property var theme
    required property var app
    // The active tab entry: {id, citekey, title, kind: "pdf", page, zoom_mode, zoom}.
    property var tab: null
    readonly property string docKey: tab ? tab.id : ""
    readonly property var ref: app.selected && tab && app.selected.id === tab.id ? app.selected : null

    // pdf_open: {doc_id, path, page_count, pages: [{x0, y0, w, h}], outline, title}
    property var doc: null
    property string status: "idle" // idle | loading | ready | error
    property string message: ""

    property string zoomMode: "width" // width | page | custom
    property real customZoom: 1
    readonly property real maxPageWidth: doc ? Math.max.apply(null, doc.pages.map(function (p) { return p.w })) : 612
    readonly property real maxPageHeight: doc ? Math.max.apply(null, doc.pages.map(function (p) { return p.h })) : 792
    readonly property real pageGap: theme.space(12)
    readonly property real fitWidth: Math.max(0.25, (pages.width - theme.space(40)) / maxPageWidth)
    readonly property real fitPage: Math.max(0.25, Math.min(fitWidth, (pages.height - pageGap * 2) / maxPageHeight))
    readonly property real zoom: zoomMode === "width" ? fitWidth : zoomMode === "page" ? fitPage : customZoom
    // Pages re-render once zooming settles; until then the old image scales.
    property real renderZoom: 1
    property real dpr: Screen.devicePixelRatio || 1
    readonly property real renderScale: Math.max(0.25, Math.min(8, Math.round(renderZoom * dpr * 4) / 4))

    property int currentPage: 1
    property int firstVisible: 1
    property int lastVisible: 1
    property string tool: "select" // select | rect
    property var renders: ({})     // page -> {path, width, height, scale, links}
    property var words: ({})       // page -> [[text, x0, y0, x1, y1, block, line]]
    property var selection: null   // {page, from, to} word indices
    property var search: null      // {query, flat: [{page, rect}], index, total, truncated}
    property bool searching: false
    property bool showOutline: false
    property bool showSide: true
    property string countDigits: ""
    property real lastG: 0

    // Render requests are queued: the service allows only a few in flight per connection.
    property var queue: []
    property int inFlight: 0
    property var pending: ({})

    readonly property bool wantsEscape: !!app.composer || tool !== "select" || selection !== null || search !== null || searchField.activeFocus
    readonly property var clips: {
        if (!ref || !doc || !ref.notes) return []
        return ref.notes.filter(function (n) {
            return n.image && n.image.source_pdf === root.doc.path && n.image.rectangle && n.image.rectangle.unit === "pt"
        })
    }

    onDocKeyChanged: open()
    // Replies lost to a reconnect never arrive; start the document over.
    Connections {
        target: root.app
        function onConnectionEpochChanged() { if (root.docKey) root.open() }
    }
    onZoomChanged: { settle.restart(); Qt.callLater(updateCurrentPage) }
    onRenderScaleChanged: requestNearby()
    onCurrentPageChanged: { persist.restart(); requestNearby() }
    onZoomModeChanged: persist.restart()
    onCustomZoomChanged: persist.restart()
    Component.onCompleted: { renderZoom = zoom; open() }

    Timer { id: settle; interval: 160; onTriggered: root.renderZoom = root.zoom }
    Timer {
        id: persist
        interval: 700
        onTriggered: {
            var at = root.app.activeTab
            if (!root.doc || at < 0 || !root.app.activePaper || root.app.activePaper.id !== root.docKey) return
            var t = root.app.activePaper
            if (t.page === root.currentPage && t.zoom_mode === root.zoomMode && t.zoom === root.customZoom) return
            root.app.updateTab(at, { page: root.currentPage, zoom_mode: root.zoomMode, zoom: root.customZoom })
        }
    }

    function open() {
        doc = null; renders = ({}); words = ({}); selection = null; search = null; searching = false
        queue = []; pending = ({}); inFlight = 0; tool = "select"; countDigits = ""
        if (!docKey) { status = "idle"; return }
        status = "loading"; message = ""
        zoomMode = tab.zoom_mode === "page" || tab.zoom_mode === "custom" ? tab.zoom_mode : "width"
        customZoom = tab.zoom > 0 ? tab.zoom : 1
        var key = docKey, page = tab.page || 1
        var id = app.rpc("pdf_open", { ref_id: key }, function (r) {
            if (root.docKey !== key) return
            root.doc = r
            root.status = "ready"
            root.renderZoom = root.zoom
            Qt.callLater(function () { if (root.docKey === key) { root.goToPage(page); root.updateCurrentPage() } })
        }, function (error) {
            if (root.docKey !== key) return
            root.status = "error"
            root.message = error
        })
        if (id < 0) { status = "error"; message = "Omabib service is unavailable" }
    }

    // Visible pages and one on either side are rendered and their text loaded.
    function near(page) { return page >= firstVisible - 1 && page <= lastVisible + 1 }
    function requestNearby() {
        if (!doc) return
        for (var p = Math.max(1, firstVisible - 1); p <= Math.min(doc.page_count, lastVisible + 1); p++) {
            requestRender(p)
            requestWords(p)
        }
    }
    function requestRender(page) {
        if (!doc) return
        var scale = renderScale, have = renders[page]
        if (have && have.scale === scale) return
        var key = page + "@" + scale
        if (pending[key]) return
        pending[key] = true
        queue.push({ page: page, scale: scale, key: key, doc: doc.doc_id })
        pump()
    }
    function pump() {
        while (inFlight < 3 && queue.length) {
            var item = queue.shift()
            // Pages scrolled far away or rendered for an old zoom are skipped.
            if (!doc || item.doc !== doc.doc_id || item.scale !== renderScale || item.page < firstVisible - 3 || item.page > lastVisible + 3) {
                delete pending[item.key]
                continue
            }
            inFlight++
            var sent = app.rpc("pdf_render", { doc_id: item.doc, page: item.page, scale: item.scale }, (function (it) {
                return function (r) {
                    root.inFlight--
                    delete root.pending[it.key]
                    if (root.doc && root.doc.doc_id === it.doc) {
                        var next = Object.assign({}, root.renders)
                        next[it.page] = r
                        root.renders = next
                    }
                    root.pump()
                }
            })(item), (function (it) {
                return function (error) {
                    root.inFlight--
                    delete root.pending[it.key]
                    // The service restarted or the file changed: open the PDF again.
                    if (/open it again/.test(error) && root.doc && root.doc.doc_id === it.doc) root.open()
                    else root.pump()
                }
            })(item))
            if (sent < 0) { inFlight--; delete pending[item.key] }
        }
    }
    function requestWords(page) {
        if (!doc || words[page] !== undefined) return
        var d = doc.doc_id
        words[page] = null
        app.rpc("pdf_text", { doc_id: d, page: page }, function (r) {
            if (!root.doc || root.doc.doc_id !== d) return
            var next = Object.assign({}, root.words)
            next[page] = r.words
            root.words = next
        }, function () { delete root.words[page] })
    }

    // --- Navigation --------------------------------------------------------
    function pageTop(page) {
        var y = 0
        for (var i = 0; i < page - 1 && i < doc.pages.length; i++) y += doc.pages[i].h * zoom + pageGap
        return y
    }
    function goToPage(page, offsetPt) {
        if (!doc) return
        page = Math.max(1, Math.min(doc.page_count, page))
        var y = pageTop(page) + (offsetPt ? Math.max(0, offsetPt * zoom - pages.height / 3) : 0)
        pages.contentY = Math.max(0, Math.min(y, pages.contentHeight - pages.height))
        updateCurrentPage()
    }
    function scrollBy(dy) {
        pages.contentY = Math.max(0, Math.min(pages.contentY + dy, pages.contentHeight - pages.height))
    }
    function updateCurrentPage() {
        if (!doc) return
        var top = pages.contentY, bottom = top + pages.height, probe = top + pages.height / 3
        var y = 0, first = 0, last = 0, current = 0
        for (var i = 0; i < doc.pages.length; i++) {
            var next = y + doc.pages[i].h * zoom + pageGap
            if (!first && next > top) first = i + 1
            if (!current && probe < next) current = i + 1
            if (y < bottom) last = i + 1
            else break
            y = next
        }
        firstVisible = first || doc.page_count
        lastVisible = Math.max(firstVisible, last)
        currentPage = current || lastVisible
        requestNearby()
    }
    function setZoom(value) {
        var anchorPage = currentPage
        customZoom = Math.max(0.25, Math.min(6, value))
        zoomMode = "custom"
        Qt.callLater(goToPage, anchorPage)
    }
    function setZoomMode(mode) {
        var anchorPage = currentPage
        zoomMode = mode
        Qt.callLater(goToPage, anchorPage)
    }

    // --- Geometry ----------------------------------------------------------
    // A rectangle in page-local logical pixels to PDF points.
    function toPoints(page, x, y, w, h) {
        var p = doc.pages[page - 1]
        return { x: p.x0 + x / zoom, y: p.y0 + y / zoom, width: w / zoom, height: h / zoom }
    }
    function fromPoints(page, rect) { // rect: [x0, y0, x1, y1]
        var p = doc.pages[page - 1]
        return Qt.rect((rect[0] - p.x0) * zoom, (rect[1] - p.y0) * zoom, (rect[2] - rect[0]) * zoom, (rect[3] - rect[1]) * zoom)
    }
    function wordAt(page, x, y) {
        var list = words[page]
        if (!list) return -1
        var p = doc.pages[page - 1], px = p.x0 + x / zoom, py = p.y0 + y / zoom
        var best = -1, bestDistance = 1e9
        for (var i = 0; i < list.length; i++) {
            var w = list[i]
            var dx = px < w[1] ? w[1] - px : px > w[3] ? px - w[3] : 0
            var dy = py < w[2] ? w[2] - py : py > w[4] ? py - w[4] : 0
            var d = dx * dx + dy * dy * 4
            if (d < bestDistance) { bestDistance = d; best = i }
        }
        return bestDistance <= 400 ? best : -1
    }
    function selectionText() {
        if (!selection || !words[selection.page]) return ""
        var list = words[selection.page], out = "", prev = null
        for (var i = Math.min(selection.from, selection.to); i <= Math.max(selection.from, selection.to); i++) {
            var w = list[i]
            if (prev) out += prev[5] !== w[5] || prev[6] !== w[6] ? "\n" : " "
            out += w[0]
            prev = w
        }
        return out
    }
    function linkAt(page, x, y) {
        var r = renders[page]
        if (!r || !r.links) return null
        var p = doc.pages[page - 1], px = p.x0 + x / zoom, py = p.y0 + y / zoom
        for (var i = 0; i < r.links.length; i++) {
            var l = r.links[i]
            if (px >= l.rect[0] && px <= l.rect[2] && py >= l.rect[1] && py <= l.rect[3] && (l.page || l.uri)) return l
        }
        return null
    }
    function clipAt(page, x, y) {
        var p = doc.pages[page - 1], px = p.x0 + x / zoom, py = p.y0 + y / zoom
        for (var i = clips.length - 1; i >= 0; i--) {
            var n = clips[i], r = n.image.rectangle
            if (n.image.page === page && px >= r.x && px <= r.x + r.width && py >= r.y && py <= r.y + r.height) return n
        }
        return null
    }

    // --- Actions -----------------------------------------------------------
    function runSearch(text) {
        if (!doc || !text.trim()) { search = null; return }
        var d = doc.doc_id
        app.rpc("pdf_search", { doc_id: d, query: text }, function (r) {
            if (!root.doc || root.doc.doc_id !== d) return
            var flat = []
            r.hits.forEach(function (h) { h.rects.forEach(function (rect) { flat.push({ page: h.page, rect: rect }) }) })
            root.search = { query: r.query, flat: flat, index: 0, total: r.total, truncated: r.truncated }
            if (flat.length) root.showHit(0)
            else root.app.flash("No matches for “" + r.query + "”")
        })
    }
    function showHit(delta) {
        if (!search || !search.flat.length) return
        var next = Object.assign({}, search)
        next.index = (search.index + delta + search.flat.length) % search.flat.length
        search = next
        var hit = search.flat[search.index]
        goToPage(hit.page, hit.rect[1] - doc.pages[hit.page - 1].y0)
    }
    // A clip (rect in page pixels) or, with no rectangle, a page note.
    function composeNote(page, box) {
        if (!doc) return
        var clip = { source_pdf: doc.path, page: page }
        if (box) {
            clip.rect_pt = toPoints(page, box.x, box.y, box.width, box.height)
            var r = renders[page], p = doc.pages[page - 1]
            if (r) clip.preview = {
                path: r.path,
                rect: Qt.rect((clip.rect_pt.x - p.x0) * r.scale, (clip.rect_pt.y - p.y0) * r.scale, clip.rect_pt.width * r.scale, clip.rect_pt.height * r.scale)
            }
        }
        tool = "select"
        app.editClip(clip)
    }
    function cancel() {
        if (app.composer) app.cancelComposer()
        else if (searchField.activeFocus) { searching = false; search = null; keys.forceActiveFocus() }
        else if (tool !== "select") tool = "select"
        else if (selection) selection = null
        else if (search) search = null
    }

    function handleKey(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        var page = pages.height * 0.9
        if (ctrl) {
            if (event.key === Qt.Key_C && selection) { app.copy(selectionText()); event.accepted = true }
            else if (event.key === Qt.Key_Equal || event.key === Qt.Key_Plus) { setZoom(zoom * 1.2); event.accepted = true }
            else if (event.key === Qt.Key_Minus) { setZoom(zoom / 1.2); event.accepted = true }
            else if (event.key === Qt.Key_0) { setZoomMode("width"); event.accepted = true }
            return
        }
        var k = event.key, t = event.text
        var count = countDigits !== "" ? Number(countDigits) : 0
        if (/^[0-9]$/.test(t) && !(t === "0" && countDigits === "")) { countDigits += t; event.accepted = true; return }
        countDigits = ""
        event.accepted = true
        if (k === Qt.Key_Escape) cancel()
        else if (t === "j" || k === Qt.Key_Down) scrollBy(theme.space(60) * Math.max(1, count))
        else if (t === "k" || k === Qt.Key_Up) scrollBy(-theme.space(60) * Math.max(1, count))
        else if (t === "h" || k === Qt.Key_Left) pages.contentX = Math.max(0, pages.contentX - theme.space(60))
        else if (t === "l" || k === Qt.Key_Right) pages.contentX = Math.min(pages.contentWidth - pages.width, pages.contentX + theme.space(60))
        else if (k === Qt.Key_PageDown || (k === Qt.Key_Space && !(event.modifiers & Qt.ShiftModifier))) scrollBy(page)
        else if (k === Qt.Key_PageUp || k === Qt.Key_Space) scrollBy(-page)
        else if (k === Qt.Key_Home) goToPage(1)
        else if (k === Qt.Key_End) goToPage(doc ? doc.page_count : 1)
        else if (t === "g") {
            if (Date.now() - lastG < 600) { goToPage(count || 1); lastG = 0 }
            else lastG = Date.now()
        }
        else if (t === "G") goToPage(count || (doc ? doc.page_count : 1))
        else if (t === "/") { searching = true; Qt.callLater(function () { searchField.forceActiveFocus(); searchField.selectAll() }) }
        else if (t === "n") showHit(1)
        else if (t === "N") showHit(-1)
        else if (t === "r") tool = tool === "rect" ? "select" : "rect"
        else if (t === "a") composeNote(currentPage, null)
        else if (t === "o") showOutline = !showOutline
        else if (t === "]") showSide = !showSide
        else if (t === "+" || t === "=") setZoom(zoom * 1.2)
        else if (t === "-") setZoom(zoom / 1.2)
        else if (t === "0" || t === "w") setZoomMode("width")
        else if (t === "z") setZoomMode("page")
        else event.accepted = false
    }

    Item { id: keys; focus: true; Keys.onPressed: event => root.handleKey(event) }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Outline.
        Rectangle {
            visible: root.showOutline
            Layout.fillHeight: true
            Layout.preferredWidth: root.theme.space(250)
            color: root.theme.card
            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                SectionLabel { theme: root.theme; text: "Contents"; Layout.margins: root.theme.space(12) }
                ListView {
                    id: outlineList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.doc ? root.doc.outline : []
                    delegate: Rectangle {
                        required property var modelData
                        width: outlineList.width
                        height: root.theme.space(28)
                        color: outlineMouse.containsMouse ? root.theme.hoverFill : "transparent"
                        Text {
                            anchors { left: parent.left; right: pageNo.left; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(12 + 14 * parent.modelData.level); rightMargin: root.theme.space(6) }
                            text: parent.modelData.title
                            color: root.theme.text
                            font.family: root.theme.readingFamily
                            font.pixelSize: root.theme.body
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                        Text {
                            id: pageNo
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: root.theme.space(12) }
                            text: parent.modelData.page || ""
                            color: root.theme.dim
                            font.family: root.theme.mono
                            font.pixelSize: root.theme.small
                        }
                        MouseArea {
                            id: outlineMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (parent.modelData.page) root.goToPage(parent.modelData.page); keys.forceActiveFocus() }
                        }
                    }
                }
                Text {
                    visible: !!root.doc && root.doc.outline.length === 0
                    Layout.margins: root.theme.space(12)
                    text: "This PDF has no outline."
                    color: root.theme.dim
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.small
                }
            }
        }
        Rectangle { visible: root.showOutline; Layout.fillHeight: true; implicitWidth: 1; color: root.theme.line }

        // Pages.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: root.theme.space(40)
                color: root.theme.card
                Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: root.theme.line }
                RowLayout {
                    anchors { fill: parent; leftMargin: root.theme.space(8); rightMargin: root.theme.space(8) }
                    spacing: root.theme.space(2)
                    IconButton { theme: root.theme; icon: "outline"; active: root.showOutline; tooltip: "Contents"; shortcut: "o"; onClicked: root.showOutline = !root.showOutline }
                    Rectangle { implicitWidth: 1; implicitHeight: root.theme.space(16); color: root.theme.line; Layout.leftMargin: root.theme.space(4); Layout.rightMargin: root.theme.space(4) }
                    TextField {
                        id: pageField
                        objectName: "readerPageField"
                        implicitWidth: root.theme.space(46)
                        implicitHeight: root.theme.space(26)
                        horizontalAlignment: TextInput.AlignRight
                        text: root.currentPage
                        color: root.theme.bright
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        validator: IntValidator { bottom: 1; top: root.doc ? root.doc.page_count : 1 }
                        background: Rectangle { color: root.theme.app; radius: root.theme.radius; border.width: 1; border.color: pageField.activeFocus ? root.theme.focusBorder : root.theme.line }
                        onAccepted: { root.goToPage(Number(text)); keys.forceActiveFocus() }
                    }
                    Text {
                        text: "/ " + (root.doc ? root.doc.page_count : "–")
                        color: root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    Rectangle { implicitWidth: 1; implicitHeight: root.theme.space(16); color: root.theme.line; Layout.leftMargin: root.theme.space(6); Layout.rightMargin: root.theme.space(4) }
                    IconButton { theme: root.theme; icon: "zoomOut"; tooltip: "Zoom out"; shortcut: "-"; onClicked: root.setZoom(root.zoom / 1.2) }
                    Text {
                        Layout.preferredWidth: root.theme.space(44)
                        horizontalAlignment: Text.AlignHCenter
                        text: Math.round(root.zoom * 100) + "%"
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    IconButton { theme: root.theme; icon: "zoomIn"; tooltip: "Zoom in"; shortcut: "+"; onClicked: root.setZoom(root.zoom * 1.2) }
                    IconButton { theme: root.theme; icon: "fitWidth"; active: root.zoomMode === "width"; tooltip: "Fit width"; shortcut: "w"; onClicked: root.setZoomMode("width") }
                    IconButton { theme: root.theme; icon: "fitPage"; active: root.zoomMode === "page"; tooltip: "Fit page"; shortcut: "z"; onClicked: root.setZoomMode("page") }
                    Rectangle { implicitWidth: 1; implicitHeight: root.theme.space(16); color: root.theme.line; Layout.leftMargin: root.theme.space(4); Layout.rightMargin: root.theme.space(4) }
                    IconButton { theme: root.theme; icon: "crop"; active: root.tool === "rect"; tooltip: "Clip a region into a note"; shortcut: "r"; onClicked: { root.tool = root.tool === "rect" ? "select" : "rect"; keys.forceActiveFocus() } }
                    IconButton { theme: root.theme; icon: "notePlus"; tooltip: "Note on this page"; shortcut: "a"; onClicked: root.composeNote(root.currentPage, null) }
                    Item { Layout.fillWidth: true }
                    TextField {
                        id: searchField
                        objectName: "readerSearchField"
                        visible: root.searching || root.search !== null
                        Layout.preferredWidth: root.theme.space(200)
                        implicitHeight: root.theme.space(26)
                        placeholderText: "Search this PDF"
                        placeholderTextColor: root.theme.dim
                        color: root.theme.bright
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        background: Rectangle { color: root.theme.app; radius: root.theme.radius; border.width: 1; border.color: searchField.activeFocus ? root.theme.focusBorder : root.theme.line }
                        onAccepted: { root.runSearch(text); keys.forceActiveFocus() }
                        Keys.onEscapePressed: root.cancel()
                    }
                    Text {
                        visible: root.search !== null
                        text: root.search && root.search.flat.length ? (root.search.index + 1) + " / " + root.search.flat.length + (root.search.truncated ? "+" : "") : "0"
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    IconButton { theme: root.theme; visible: root.search !== null; icon: "chevronUp"; tooltip: "Previous match"; shortcut: "N"; onClicked: root.showHit(-1) }
                    IconButton { theme: root.theme; visible: root.search !== null; icon: "chevronDown"; tooltip: "Next match"; shortcut: "n"; onClicked: root.showHit(1) }
                    IconButton { theme: root.theme; icon: "search"; active: root.searching; tooltip: "Search"; shortcut: "/"; onClicked: { root.searching = true; searchField.forceActiveFocus() } }
                    IconButton { theme: root.theme; icon: "sidebar"; active: root.showSide; tooltip: "Notes pane"; shortcut: "]"; onClicked: root.showSide = !root.showSide }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                Rectangle { anchors.fill: parent; color: Qt.darker(root.theme.app, root.theme.light ? 1.08 : 1.25) }

                Flickable {
                    id: pages
                    objectName: "readerPages"
                    anchors.fill: parent
                    visible: root.status === "ready"
                    contentWidth: Math.max(width, root.maxPageWidth * root.zoom + root.theme.space(40))
                    contentHeight: column.implicitHeight + root.pageGap
                    boundsBehavior: Flickable.StopAtBounds
                    // Drags select text or draw clips; the wheel and scroll bars scroll.
                    acceptedButtons: Qt.NoButton
                    onContentYChanged: root.updateCurrentPage()
                    onHeightChanged: root.updateCurrentPage()

                    WheelHandler {
                        acceptedModifiers: Qt.ControlModifier
                        onWheel: event => root.setZoom(root.zoom * (event.angleDelta.y > 0 ? 1.1 : 1 / 1.1))
                    }

                    Column {
                        id: column
                        y: root.pageGap
                        width: pages.contentWidth
                        spacing: root.pageGap
                        Repeater {
                            model: root.doc ? root.doc.page_count : 0
                            delegate: PdfPage {}
                        }
                    }

                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                }

                BusyIndicator { anchors.centerIn: parent; running: root.status === "loading"; visible: running }
                EmptyState {
                    theme: root.theme
                    anchors.centerIn: parent
                    visible: root.status === "error"
                    icon: "alert"
                    title: "Couldn't open this PDF"
                    detail: root.message
                    TextButton { theme: root.theme; icon: "refresh"; text: "Try again"; onClicked: root.open() }
                }
                Rectangle {
                    visible: root.tool === "rect"
                    anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: root.theme.space(10) }
                    implicitWidth: toolHint.implicitWidth + root.theme.space(20)
                    implicitHeight: root.theme.space(28)
                    radius: root.theme.radius
                    color: root.theme.card
                    border.width: 1
                    border.color: root.theme.accent
                    Text {
                        id: toolHint
                        anchors.centerIn: parent
                        text: "Drag over a region to clip it into a note  ·  Esc cancels"
                        color: root.theme.bright
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                }
            }
        }

        // The reference beside the pages, like Zotero's item pane.
        Rectangle { visible: root.showSide; Layout.fillHeight: true; implicitWidth: 1; color: root.theme.line }
        Rectangle {
            visible: root.showSide
            Layout.fillHeight: true
            Layout.preferredWidth: Math.round(Math.max(root.theme.space(320), Math.min(root.theme.space(460), root.width * 0.3)))
            color: root.theme.card
            clip: true
            ColumnLayout {
                anchors.fill: parent
                spacing: 0
                Text {
                    Layout.fillWidth: true
                    Layout.margins: root.theme.space(14)
                    Layout.bottomMargin: root.theme.space(4)
                    text: root.ref ? (root.ref.title || root.ref.citekey) : (root.tab ? root.tab.title : "")
                    color: root.theme.bright
                    font.family: root.theme.readingFamily
                    font.pixelSize: root.theme.subtitle
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                SegmentedTabs {
                    Layout.fillWidth: true
                    Layout.leftMargin: root.theme.space(8)
                    theme: root.theme
                    current: side.key
                    tabs: [
                        { key: "notes", label: "Notes", count: root.ref && root.ref.notes ? root.ref.notes.length : 0 },
                        { key: "overview", label: "Abstract" },
                        { key: "ai", label: "AI summary", icon: "sparkles", visible: !!root.ref && root.app.arxivIdOf(root.ref) !== "" }
                    ]
                    onSelected: key => { if (root.app.composer) root.app.cancelComposer(); root.app.selectTab(key) }
                }
                NoteComposer {
                    id: composer
                    objectName: "noteComposer"
                    visible: !!root.app.composer
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 0
                    theme: root.theme
                    app: root.app
                }
                StackLayout {
                    id: side
                    visible: !root.app.composer
                    readonly property var sections: ["notes", "overview", "ai"]
                    readonly property string key: sections.indexOf(root.app.detailTab) >= 0 ? root.app.detailTab : "notes"
                    // The AI summary's header row would otherwise force the pane wider than it is.
                    Layout.minimumWidth: 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: sections.indexOf(key)
                    NotesTab { theme: root.theme; app: root.app; sidePadding: root.theme.space(14) }
                    OverviewTab { theme: root.theme; app: root.app; sidePadding: root.theme.space(14) }
                    AiSummaryTab { theme: root.theme; app: root.app }
                }
            }
        }
    }

    component PdfPage: Item {
        id: pageItem
        required property int index
        readonly property int page: index + 1
        readonly property var info: root.doc.pages[index]
        readonly property var render: root.renders[page]
        readonly property real sheetWidth: info.w * root.zoom
        readonly property real sheetHeight: info.h * root.zoom
        // Rubber band and selection drag state, in sheet pixels.
        property point pressAt: Qt.point(0, 0)
        property point dragAt: Qt.point(0, 0)
        property bool dragging: false

        objectName: "readerPage" + page
        width: column.width
        height: sheetHeight


        Rectangle {
            id: sheet
            objectName: "readerSheet"
            x: Math.round((pageItem.width - pageItem.sheetWidth) / 2)
            width: pageItem.sheetWidth
            height: pageItem.sheetHeight
            color: "white"

            Image {
                anchors.fill: parent
                // Far pages drop their image so long documents don't hold every page in memory.
                source: pageItem.render && pageItem.page >= root.firstVisible - 4 && pageItem.page <= root.lastVisible + 4 ? root.app.fileUrl(pageItem.render.path) : ""
                asynchronous: true
                cache: false
                smooth: true
                mipmap: true
                retainWhileLoading: true
            }

            Repeater {
                model: root.search ? root.search.flat.filter(function (h) { return h.page === pageItem.page }) : []
                Rectangle {
                    required property var modelData
                    readonly property rect box: root.fromPoints(pageItem.page, modelData.rect)
                    readonly property bool current: root.search && root.search.flat[root.search.index] === modelData
                    x: box.x; y: box.y; width: box.width; height: box.height
                    color: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, current ? 0.45 : 0.22)
                }
            }

            Repeater {
                model: {
                    var s = root.selection, list = root.words[pageItem.page]
                    if (!s || s.page !== pageItem.page || !list) return []
                    return list.slice(Math.min(s.from, s.to), Math.max(s.from, s.to) + 1)
                }
                Rectangle {
                    required property var modelData
                    readonly property rect box: root.fromPoints(pageItem.page, [modelData[1], modelData[2], modelData[3], modelData[4]])
                    x: box.x - 1; y: box.y; width: box.width + 3; height: box.height
                    color: Qt.rgba(0.2, 0.45, 1, 0.3)
                }
            }

            Repeater {
                model: root.clips.filter(function (n) { return n.image.page === pageItem.page })
                Rectangle {
                    id: clipBox
                    required property var modelData
                    readonly property var r: modelData.image.rectangle
                    objectName: "readerClip"
                    x: (r.x - pageItem.info.x0) * root.zoom
                    y: (r.y - pageItem.info.y0) * root.zoom
                    width: r.width * root.zoom
                    height: r.height * root.zoom
                    color: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, clipHover.hovered ? 0.16 : 0.07)
                    border.width: 2
                    border.color: root.theme.accent
                    HoverHandler { id: clipHover; cursorShape: Qt.PointingHandCursor }
                    PanelToolTip {
                        visible: clipHover.hovered
                        text: (clipBox.modelData.body || "Clip").slice(0, 160) + "  ·  click to edit"
                        fontFamily: root.theme.mono
                    }
                }
            }

            // The clip being written in the side pane.
            Rectangle {
                readonly property var pending: root.app.composer && !root.app.composer.note && root.app.composer.clip && root.app.composer.clip.rect_pt && root.app.composer.clip.page === pageItem.page ? root.app.composer.clip.rect_pt : null
                visible: !!pending
                x: pending ? (pending.x - pageItem.info.x0) * root.zoom : 0
                y: pending ? (pending.y - pageItem.info.y0) * root.zoom : 0
                width: pending ? pending.width * root.zoom : 0
                height: pending ? pending.height * root.zoom : 0
                color: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.12)
                border.width: 2
                border.color: root.theme.accent
            }
            Rectangle {
                visible: pageItem.dragging && root.tool === "rect"
                x: Math.min(pageItem.pressAt.x, pageItem.dragAt.x)
                y: Math.min(pageItem.pressAt.y, pageItem.dragAt.y)
                width: Math.abs(pageItem.dragAt.x - pageItem.pressAt.x)
                height: Math.abs(pageItem.dragAt.y - pageItem.pressAt.y)
                color: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.12)
                border.width: 2
                border.color: root.theme.accent
            }

            MouseArea {
                id: pageMouse
                objectName: "readerPageMouse"
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.tool === "rect" ? Qt.CrossCursor
                    : root.linkAt(pageItem.page, mouseX, mouseY) ? Qt.PointingHandCursor : Qt.IBeamCursor
                onPressed: mouse => {
                    keys.forceActiveFocus()
                    pageItem.pressAt = Qt.point(mouse.x, mouse.y)
                    pageItem.dragAt = pageItem.pressAt
                    pageItem.dragging = false
                    if (root.tool === "select") root.requestWords(pageItem.page)
                }
                onPositionChanged: mouse => {
                    if (!pressed) return
                    pageItem.dragAt = Qt.point(Math.max(0, Math.min(width, mouse.x)), Math.max(0, Math.min(height, mouse.y)))
                    if (Math.abs(pageItem.dragAt.x - pageItem.pressAt.x) + Math.abs(pageItem.dragAt.y - pageItem.pressAt.y) > 3) pageItem.dragging = true
                    if (pageItem.dragging && root.tool === "select") {
                        var from = root.wordAt(pageItem.page, pageItem.pressAt.x, pageItem.pressAt.y)
                        var to = root.wordAt(pageItem.page, pageItem.dragAt.x, pageItem.dragAt.y)
                        if (from >= 0 && to >= 0) root.selection = { page: pageItem.page, from: from, to: to }
                    }
                }
                onReleased: mouse => {
                    if (root.tool === "rect") {
                        var box = Qt.rect(Math.min(pageItem.pressAt.x, pageItem.dragAt.x), Math.min(pageItem.pressAt.y, pageItem.dragAt.y),
                                          Math.abs(pageItem.dragAt.x - pageItem.pressAt.x), Math.abs(pageItem.dragAt.y - pageItem.pressAt.y))
                        pageItem.dragging = false
                        root.composeNote(pageItem.page, box.width > 3 && box.height > 3 ? box : null)
                        return
                    }
                    if (pageItem.dragging) { pageItem.dragging = false; return }
                    var clip = root.clipAt(pageItem.page, mouse.x, mouse.y)
                    var link = root.linkAt(pageItem.page, mouse.x, mouse.y)
                    root.selection = null
                    if (clip) root.app.edit("note", clip)
                    else if (link && link.page) root.goToPage(link.page)
                    else if (link && link.uri) root.app.openExternal(link.uri)
                }
                onDoubleClicked: mouse => {
                    var w = root.wordAt(pageItem.page, mouse.x, mouse.y)
                    if (w >= 0) root.selection = { page: pageItem.page, from: w, to: w }
                }
            }
        }
    }
}
