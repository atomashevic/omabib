import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import "Wheel.js" as Wheel

// A PDF reader tab. The service renders pages with MuPDF; this pane lays them
// out, selects and searches text, highlights it (the highlighter tool, or a
// selection's right-click menu), and turns a dragged rectangle into a clip
// note. The reference's notes, highlights, overview and AI summary sit beside
// the pages. A highlight is stored in the library. The PDF is not.
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
    // The pages and the gaps above them, from the page sizes rather than the
    // column's layout, so a zoom can place the view before the column relays out.
    readonly property real docHeight: doc ? doc.pages.reduce(function (y, p) { return y + p.h * zoom + pageGap }, 0) : 0
    // Pages re-render once zooming settles; until then the old image scales.
    property real renderZoom: 1
    property real dpr: Screen.devicePixelRatio || 1
    readonly property real renderScale: Math.max(0.25, Math.min(8, Math.round(renderZoom * dpr * 4) / 4))

    property int currentPage: 1
    property int firstVisible: 1
    property int lastVisible: 1
    property string tool: "select" // select | rect | highlight
    // The color a new highlight takes: the highlighter's, or the last one a
    // selection was highlighted in.
    property string highlightColor: "yellow"
    readonly property var highlightColors: ["yellow", "red", "green", "purple", "blue"]
    // The side pane shows this PDF's highlights rather than a reference section.
    property bool sideHighlights: false
    // A highlight just jumped to, outlined for a moment.
    property string focusMark: ""
    property var renders: ({})     // page -> {path, width, height, scale, links}
    property var words: ({})       // page -> [[text, x0, y0, x1, y1, block, line]]
    property var selection: null   // {page, from, to} word indices
    property var highlights: []    // {id, page, rects, quote, color, comment} for this PDF
    property int highlightEpoch: 0
    readonly property bool highlightMenuOpen: highlightPopover.opened
    readonly property bool contextMenuOpen: contextMenu.opened
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

    readonly property bool wantsEscape: !!app.composer || highlightPopover.opened || contextMenu.opened || tool !== "select" || selection !== null || search !== null || searchField.activeFocus
    readonly property var clips: {
        if (!ref || !doc || !ref.notes) return []
        return ref.notes.filter(function (n) {
            return n.image && n.image.source_pdf === root.doc.path && n.image.rectangle && n.image.rectangle.unit === "pt"
        })
    }

    onDocKeyChanged: open()
    // Another section asked for (the chat, a note) takes the side pane back.
    Connections {
        target: root.app
        function onDetailTabChanged() { root.sideHighlights = false }
    }
    Timer { id: unfocusMark; interval: 1600; onTriggered: root.focusMark = "" }
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
        highlights = []; highlightEpoch++; highlightPopover.close(); contextMenu.close()
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
            root.loadHighlights()
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
    // Same notch and touchpad rules as every other view.
    function wheelScroll(event) {
        Wheel.apply(pages, event, Wheel.stepFor(root.theme))
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
    // Zooms keeping the spot at (x, y) in the view, by default its centre,
    // where it is.
    function setZoom(value, x, y) {
        if (x === undefined) { x = pages.width / 2; y = pages.height / 2 }
        var spot = doc ? spotAt(x, y) : null
        customZoom = Math.max(0.25, Math.min(6, value))
        zoomMode = "custom"
        if (spot) showSpot(spot, x, y)
    }
    // Fit page shows the current page whole; fit width keeps the centre.
    function setZoomMode(mode) {
        var page = currentPage, spot = doc ? spotAt(pages.width / 2, pages.height / 2) : null
        zoomMode = mode
        if (mode === "page") goToPage(page)
        else if (spot) showSpot(spot, pages.width / 2, pages.height / 2)
    }
    // The page under (x, y) in the view, and the point there in PDF points
    // from the page's top-left corner.
    function spotAt(x, y) {
        var cy = pages.contentY + y - pageGap, page = 1, top = 0
        while (page < doc.page_count && cy >= top + doc.pages[page - 1].h * zoom + pageGap) {
            top += doc.pages[page - 1].h * zoom + pageGap
            page++
        }
        var w = doc.pages[page - 1].w * zoom
        return { page: page, x: (pages.contentX + x - (pages.contentWidth - w) / 2) / zoom, y: (cy - top) / zoom }
    }
    // Scrolls so the spot is at (x, y) in the view.
    function showSpot(spot, x, y) {
        var w = doc.pages[spot.page - 1].w * zoom
        scrollTo((pages.contentWidth - w) / 2 + spot.x * zoom - x, pageGap + pageTop(spot.page) + spot.y * zoom - y)
        updateCurrentPage()
    }
    function scrollTo(x, y) {
        pages.contentX = Math.max(0, Math.min(x, pages.contentWidth - pages.width))
        pages.contentY = Math.max(0, Math.min(y, pages.contentHeight - pages.height))
    }
    // Ctrl+wheel zooms by 10% a notch, a touchpad by how far it moved,
    // keeping the spot under the pointer in place.
    function wheelZoom(event, scenePosition) {
        var notches = event.pixelDelta.y !== 0 ? event.pixelDelta.y / 50 : event.angleDelta.y / 120
        if (notches === 0) return
        var at = pages.mapFromItem(null, scenePosition.x, scenePosition.y)
        setZoom(zoom * Math.pow(1.1, notches), at.x, at.y)
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
    // Words from..to as a passage: lines run together, a word hyphenated at a
    // line's end is closed up, and paragraphs (MuPDF's blocks) stay apart.
    function passage(page, from, to) {
        var list = words[page]
        if (!list) return ""
        var out = "", prev = null
        for (var i = Math.min(from, to); i <= Math.max(from, to); i++) {
            var w = list[i]
            if (prev) {
                var first = w[0].charAt(0)
                var lower = first !== first.toUpperCase() && first === first.toLowerCase()
                if (prev[5] !== w[5]) out += "\n\n"
                // "state-of-" keeps its hyphen: a compound, not a broken word.
                else if (prev[6] !== w[6] && prev[0].length > 1 && prev[0].indexOf("-") === prev[0].length - 1 && lower) out = out.slice(0, -1)
                else out += " "
            }
            out += w[0]
            prev = w
        }
        return out
    }
    function selectionText() {
        return selection ? passage(selection.page, selection.from, selection.to) : ""
    }
    // A passage as Markdown: a block quote that cites its page, for Pandoc.
    function quoteMarkdown(text, page) {
        var key = (ref && ref.citekey) || (tab && tab.citekey) || ""
        var quoted = text.split("\n\n").map(function (p) { return "> " + p }).join("\n>\n")
        return quoted + "\n>\n> " + (key ? "[@" + key + ", p. " + page + "]" : "p. " + page)
    }
    function copyPassage(text, page, markdown) {
        if (text) app.copy(markdown ? quoteMarkdown(text, page) : text)
    }
    // The passage goes to the chat beside the page as a quote with its page.
    function quoteInChat(text, page) {
        if (!text) return
        selection = null
        sideHighlights = false
        if (!showSide) showSide = true
        app.askAboutSelection(page, text)
    }
    // A page note that starts with the passage quoted.
    function noteAbout(text, page) {
        if (!doc || !text) return
        selection = null
        sideHighlights = false
        if (!showSide) showSide = true
        app.editClip({ source_pdf: doc.path, page: page })
        if (app.composer) app.composer = Object.assign({}, app.composer, { body: text.split("\n\n").map(function (p) { return "> " + p }).join("\n>\n") + "\n\n" })
    }
    function selectionContains(page, x, y) {
        if (!selection || selection.page !== page || !doc) return false
        var p = doc.pages[page - 1], px = p.x0 + x / zoom, py = p.y0 + y / zoom
        return lineRects(page, Math.min(selection.from, selection.to), Math.max(selection.from, selection.to)).some(function (r) {
            return px >= r[0] - 2 && px <= r[2] + 2 && py >= r[1] - 2 && py <= r[3] + 2
        })
    }
    // One box per line, the union of the word boxes on that line.
    function lineRects(page, from, to) {
        var list = words[page]
        if (!list) return []
        var rects = [], line = null, prev = null
        for (var i = from; i <= to; i++) {
            var w = list[i]
            var same = prev && prev[5] === w[5] && prev[6] === w[6]
            if (!same) {
                if (line) rects.push(line)
                line = [w[1], w[2], w[3], w[4]]
            } else {
                line[0] = Math.min(line[0], w[1])
                line[1] = Math.min(line[1], w[2])
                line[2] = Math.max(line[2], w[3])
                line[3] = Math.max(line[3], w[4])
            }
            prev = w
        }
        if (line) rects.push(line)
        return rects
    }
    function highlightInk(name, solid) {
        var hex = { yellow: "#f5d90a", red: "#e5484d", green: "#30a46c", purple: "#8e4ec6", blue: "#3b82f6" }
        var c = Qt.color(hex[name] || hex.yellow)
        return solid ? c : Qt.rgba(c.r, c.g, c.b, 0.45)
    }
    function paintHighlight(row) {
        return {
            id: row.id, page: row.page, rects: row.rects, quote: row.quote,
            color: row.color || "yellow", comment: row.comment || "", created_at: row.created_at
        }
    }
    function loadHighlights() {
        if (!doc || !doc.ref_id || !doc.attachment_id) return
        var epoch = highlightEpoch, key = doc.doc_id
        app.rpc("pdf_highlights", { ref_id: doc.ref_id, attachment_id: doc.attachment_id }, function (r) {
            if (epoch !== root.highlightEpoch || !root.doc || root.doc.doc_id !== key) return
            root.highlights = r.highlights || []
        })
    }
    // The selection as a highlight in `color` (the highlighter's by default).
    // The selection then goes, as it does under a highlighter.
    function highlightSelection(color) {
        if (!doc || !doc.ref_id || !doc.attachment_id || !selection || !words[selection.page]) return
        color = color || highlightColor
        var from = Math.min(selection.from, selection.to), to = Math.max(selection.from, selection.to)
        var page = selection.page, rects = lineRects(page, from, to), quote = selectionText()
        if (!rects.length || !quote) return
        var key = doc.doc_id
        highlightColor = color
        highlightEpoch++
        selection = null
        app.rpc("add_highlight", {
            ref_id: doc.ref_id, attachment_id: doc.attachment_id,
            page: page, rects: rects, quote: quote, color: color
        }, function (row) {
            if (!root.doc || root.doc.doc_id !== key || !row || !row.id) return
            root.highlights = root.highlights.concat([root.paintHighlight(row)])
        })
    }
    function applyHighlight(row) {
        var painted = paintHighlight(row), next = [], found = false
        for (var i = 0; i < highlights.length; i++) {
            if (highlights[i].id === painted.id) { next.push(painted); found = true }
            else next.push(highlights[i])
        }
        if (!found) next.push(painted)
        highlights = next
        if (highlightPopover.mark && highlightPopover.mark.id === painted.id) highlightPopover.mark = painted
    }
    function recolor(mark, color) {
        if (!mark || mark.color === color) return
        app.rpc("update_highlight", { id: mark.id, color: color }, function (row) {
            if (row && row.id) root.applyHighlight(row)
        })
    }
    function setHighlightColor(color) { recolor(highlightPopover.mark, color) }
    function saveHighlightComment(text) {
        var mark = highlightPopover.mark
        if (!mark || text === highlightPopover.heldComment) return
        highlightPopover.heldComment = text
        app.rpc("update_highlight", { id: mark.id, comment: text }, function (row) {
            if (row && row.id) root.applyHighlight(row)
        })
    }
    function removeHighlight(mark) {
        if (!mark) return
        app.rpc("delete_highlight", { id: mark.id }, function (row) {
            if (!row || row.deleted !== true) return
            root.highlights = root.highlights.filter(function (h) { return h.id !== mark.id })
            highlightPopover.close()
        })
    }
    // The PDF's highlights in reading order: by page, then down the page.
    readonly property var orderedHighlights: highlights.slice().sort(function (a, b) {
        return a.page - b.page || (a.rects && b.rects ? a.rects[0][1] - b.rects[0][1] : 0)
    })
    function goToHighlight(mark) {
        if (!doc || !mark || !mark.rects || !mark.rects.length) return
        goToPage(mark.page, Math.max(0, mark.rects[0][1] - doc.pages[mark.page - 1].y0))
        focusMark = mark.id
        unfocusMark.restart()
    }
    function swatches(current, prefix) {
        return highlightColors.map(function (c) { return { key: prefix + c, color: root.highlightInk(c, true), selected: c === current } })
    }
    // The right-click menu: for the selection, else for the highlight under
    // the pointer, else for the page.
    function openMenu(item, page, x, y) {
        var mark = highlightAt(page, x, y)
        if (selection && (selectionContains(page, x, y) || !mark)) {
            contextMenu.target = { page: selection.page, text: selectionText() }
            contextMenu.items = [
                { key: "copy", label: "Copy", icon: "copy", shortcut: "Ctrl+C" },
                { key: "markdown", label: "Copy as Markdown", icon: "quote" },
                { separator: true },
                { key: "highlight", label: "Highlight", icon: "highlighter", shortcut: "m" },
                { swatches: swatches(highlightColor, "highlight:") },
                { separator: true },
                { key: "chat", label: "Add to chat as quote", icon: "chatQuote", shortcut: "c" },
                { key: "note", label: "Add a note about this", icon: "notePlus" }
            ]
        } else if (mark) {
            openMarkMenu(mark, item, x, y)
            return
        } else {
            contextMenu.target = { page: page }
            contextMenu.items = [
                { key: "pageNote", label: "Note on this page", icon: "notePlus", shortcut: "a" },
                { key: "clip", label: "Clip a region", icon: "crop", shortcut: "r" },
                { key: "tool", label: tool === "highlight" ? "Stop highlighting" : "Highlight text", icon: "highlighter", shortcut: "m" }
            ]
        }
        contextMenu.openAtPoint(item, x, y)
    }
    // A saved highlight's menu, on the page or in the Highlights list.
    function openMarkMenu(mark, item, x, y) {
        selection = null
        contextMenu.target = { page: mark.page, text: mark.quote, mark: mark }
        contextMenu.items = [
            { key: "copy", label: "Copy", icon: "copy" },
            { key: "markdown", label: "Copy as Markdown", icon: "quote" },
            { separator: true },
            { swatches: swatches(mark.color, "color:") },
            { key: "comment", label: mark.comment ? "Edit comment" : "Add a comment", icon: "pencil" },
            { key: "chat", label: "Add to chat as quote", icon: "chatQuote" },
            { key: "note", label: "Add a note about this", icon: "notePlus" },
            { separator: true },
            { key: "delete", label: "Delete highlight", icon: "trash", danger: true }
        ]
        contextMenu.openAtPoint(item, x, y)
    }
    // The highlighter's color, from the dot beside it.
    function openColorMenu(anchor) {
        contextMenu.target = {}
        contextMenu.items = [{ section: "Highlight color" }, { swatches: swatches(highlightColor, "tool:") }]
        contextMenu.openAtPoint(anchor, 0, 0)
    }
    function runMenu(key) {
        var t = contextMenu.target || {}
        if (key === "copy") copyPassage(t.text, t.page, false)
        else if (key === "markdown") copyPassage(t.text, t.page, true)
        else if (key === "highlight") highlightSelection(highlightColor)
        else if (key.indexOf("highlight:") === 0) highlightSelection(key.slice(10))
        else if (key.indexOf("color:") === 0) recolor(t.mark, key.slice(6))
        else if (key.indexOf("tool:") === 0) { highlightColor = key.slice(5); tool = "highlight" }
        else if (key === "chat") quoteInChat(t.text, t.page)
        else if (key === "note") noteAbout(t.text, t.page)
        else if (key === "delete") removeHighlight(t.mark)
        else if (key === "pageNote") composeNote(t.page, null)
        else if (key === "clip") tool = "rect"
        else if (key === "tool") tool = tool === "highlight" ? "select" : "highlight"
        if (key === "comment") {
            openHighlight(t.mark, root, contextMenu.x, contextMenu.y)
            commentField.forceActiveFocus()
        } else if (key !== "chat" && key !== "note") keys.forceActiveFocus()
    }
    function highlightAt(page, x, y) {
        if (!doc) return null
        var p = doc.pages[page - 1], px = p.x0 + x / zoom, py = p.y0 + y / zoom, hit = null
        for (var i = 0; i < highlights.length; i++) {
            var h = highlights[i]
            if (h.page !== page || !h.rects) continue
            for (var j = 0; j < h.rects.length; j++) {
                var r = h.rects[j]
                if (px >= r[0] && px <= r[2] && py >= r[1] && py <= r[3]) hit = h
            }
        }
        return hit
    }
    function openHighlight(mark, item, x, y) {
        highlightPopover.mark = mark
        highlightPopover.heldComment = mark.comment || ""
        commentField.text = mark.comment || ""
        var p = item.mapToItem(root, x, y)
        var popW = highlightPopover.width, popH = root.theme.space(132)
        highlightPopover.x = Math.max(root.theme.space(8), Math.min(p.x, width - popW - root.theme.space(8)))
        highlightPopover.y = Math.max(root.theme.space(8), Math.min(p.y + root.theme.space(8), height - popH - root.theme.space(8)))
        highlightPopover.open()
    }
    function linkAt(page, x, y) {
        var r = renders[page]
        if (!r || !r.links || !doc) return null
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
        if (contextMenu.opened) contextMenu.close()
        else if (app.composer) app.cancelComposer()
        else if (highlightPopover.opened) highlightPopover.close()
        else if (searchField.activeFocus) { searching = false; search = null; keys.forceActiveFocus() }
        else if (tool !== "select") tool = "select"
        else if (selection) selection = null
        else if (search) search = null
    }

    function handleKey(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        var page = pages.height * 0.9
        if (ctrl) {
            if (event.key === Qt.Key_C && selection) { copyPassage(selectionText(), selection.page, false); event.accepted = true }
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
        // Highlight the selection, or pick up and put down the highlighter.
        else if (t === "m") {
            if (selection) highlightSelection(highlightColor)
            else tool = tool === "highlight" ? "select" : "highlight"
        }
        else if (t === "a") composeNote(currentPage, null)
        else if (t === "o") showOutline = !showOutline
        else if (t === "c") {
            // Chat about the selection, or just open the chat.
            if (selection) quoteInChat(selectionText(), selection.page)
            else { sideHighlights = false; app.focusChat() }
            if (!showSide) showSide = true
        }
        else if (t === "]") showSide = !showSide
        else if (t === "+" || t === "=") setZoom(zoom * 1.2)
        else if (t === "-") setZoom(zoom / 1.2)
        else if (t === "0" || t === "w") setZoomMode("width")
        else if (t === "z") setZoomMode("page")
        else event.accepted = false
    }

    Item { id: keys; focus: true; Keys.onPressed: event => root.handleKey(event) }
    // Keys back to the pages, even when the side pane's chat or composer had focus
    // (forceActiveFocus on the scope would return to that).
    function focusPages() { keys.forceActiveFocus() }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Outline.
        Rectangle {
            visible: root.showOutline
            Layout.fillHeight: true
            Layout.preferredWidth: root.theme.space(250)
            color: root.theme.side
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
                    boundsBehavior: Flickable.StopAtBounds
                    WheelScroll { theme: root.theme }
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
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                }
            }
        }
        Rectangle { visible: root.showOutline; Layout.fillHeight: true; implicitWidth: 1; color: root.theme.line }

        // Pages, on a canvas a step back from the window, with the page
        // controls floating over them.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            Rectangle { anchors.fill: parent; color: root.theme.canvas }

            Flickable {
                id: pages
                objectName: "readerPages"
                anchors.fill: parent
                visible: root.status === "ready"
                contentWidth: Math.max(width, root.maxPageWidth * root.zoom + root.theme.space(40))
                // Room under the last page for the page controls floating over it.
                contentHeight: root.docHeight + controls.height + root.theme.space(28)
                boundsBehavior: Flickable.StopAtBounds
                // Drags select text or draw clips; the wheel and scroll bars scroll.
                acceptedButtons: Qt.NoButton
                onContentYChanged: root.updateCurrentPage()
                onHeightChanged: root.updateCurrentPage()

                // Ctrl+wheel zooms at the pointer; the wheel alone scrolls.
                WheelHandler {
                    id: pagesWheel
                    target: null
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        if (event.modifiers & Qt.ControlModifier) root.wheelZoom(event, pagesWheel.point.scenePosition)
                        else root.wheelScroll(event)
                    }
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

            // Middle-drag pans the pages, as in most readers.
            DragHandler {
                target: null
                acceptedButtons: Qt.MiddleButton
                dragThreshold: 0
                cursorShape: Qt.ClosedHandCursor
                property point start
                onActiveChanged: if (active) start = Qt.point(pages.contentX, pages.contentY)
                onCentroidChanged: if (active) root.scrollTo(start.x - (centroid.scenePosition.x - centroid.scenePressPosition.x),
                                                             start.y - (centroid.scenePosition.y - centroid.scenePressPosition.y))
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
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: root.theme.space(12) }
                implicitWidth: toolHint.implicitWidth + root.theme.space(24)
                implicitHeight: root.theme.space(32)
                radius: root.theme.radiusLarge
                color: root.theme.raised
                border.width: 1
                border.color: root.theme.accent
                Shadow { theme: root.theme; radius: parent.radius; reach: 10 }
                Text {
                    id: toolHint
                    anchors.centerIn: parent
                    text: "Drag over a region to clip it into a note  ·  Esc cancels"
                    color: root.theme.bright
                    font.family: root.theme.sans
                    font.pixelSize: root.theme.small
                    font.weight: Font.Medium
                }
            }

            Rectangle {
                id: controls
                objectName: "readerControls"
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: root.theme.space(18) }
                implicitWidth: controlRow.implicitWidth + root.theme.space(8)
                implicitHeight: controlRow.implicitHeight + root.theme.space(8)
                radius: root.theme.radiusLarge
                color: root.theme.raised
                border.color: root.theme.line
                Shadow { theme: root.theme; radius: controls.radius; reach: 16 }
                // The wheel over the controls scrolls and zooms as it does over the pages.
                WheelHandler {
                    id: controlsWheel
                    target: null
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        if (event.modifiers & Qt.ControlModifier) root.wheelZoom(event, controlsWheel.point.scenePosition)
                        else root.wheelScroll(event)
                    }
                }

                RowLayout {
                    id: controlRow
                    anchors.centerIn: parent
                    spacing: root.theme.space(2)
                    IconButton { theme: root.theme; icon: "outline"; active: root.showOutline; tooltip: "Contents"; shortcut: "o"; onClicked: root.showOutline = !root.showOutline }
                    Divider {}
                    IconButton { theme: root.theme; icon: "chevronLeft"; enabled: root.currentPage > 1; tooltip: "Previous page"; onClicked: root.goToPage(root.currentPage - 1) }
                    TextField {
                        id: pageField
                        objectName: "readerPageField"
                        // Wide enough for the last page's number.
                        implicitWidth: Math.max(root.theme.space(30), pageDigits.advanceWidth + root.theme.space(12))
                        implicitHeight: root.theme.space(26)
                        horizontalAlignment: TextInput.AlignHCenter
                        padding: 0
                        text: root.currentPage
                        color: root.theme.bright
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        validator: IntValidator { bottom: 1; top: root.doc ? root.doc.page_count : 1 }
                        background: Rectangle {
                            radius: root.theme.radiusSmall
                            color: pageField.activeFocus ? root.theme.app : pageHover.hovered ? root.theme.hoverFill : "transparent"
                            border.width: pageField.activeFocus ? 1 : 0
                            border.color: root.theme.focusBorder
                        }
                        HoverHandler { id: pageHover; cursorShape: Qt.IBeamCursor }
                        TextMetrics { id: pageDigits; font: pageField.font; text: String(root.doc ? root.doc.page_count : 0) }
                        onAccepted: { root.goToPage(Number(text)); keys.forceActiveFocus() }
                    }
                    Text {
                        text: "/ " + (root.doc ? root.doc.page_count : "–")
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    IconButton { theme: root.theme; icon: "chevronRight"; enabled: !!root.doc && root.currentPage < root.doc.page_count; tooltip: "Next page"; onClicked: root.goToPage(root.currentPage + 1) }
                    Divider {}
                    IconButton { theme: root.theme; icon: "zoomOut"; tooltip: "Zoom out"; shortcut: "-"; onClicked: root.setZoom(root.zoom / 1.2) }
                    Text {
                        Layout.preferredWidth: root.theme.space(42)
                        horizontalAlignment: Text.AlignHCenter
                        text: Math.round(root.zoom * 100) + "%"
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    IconButton { theme: root.theme; icon: "zoomIn"; tooltip: "Zoom in"; shortcut: "+"; onClicked: root.setZoom(root.zoom * 1.2) }
                    IconButton { theme: root.theme; icon: "fitWidth"; active: root.zoomMode === "width"; tooltip: "Fit width"; shortcut: "w"; onClicked: root.setZoomMode("width") }
                    IconButton { theme: root.theme; icon: "fitPage"; active: root.zoomMode === "page"; tooltip: "Fit page"; shortcut: "z"; onClicked: root.setZoomMode("page") }
                    Divider {}
                    IconButton { theme: root.theme; objectName: "readerColorsButton"; icon: "pageColors"; active: root.app.pdfThemed; tooltip: root.app.pdfThemed ? "Original page colors" : "Theme page colors"; shortcut: "Ctrl+R"; onClicked: root.app.togglePdfColors() }
                    IconButton { theme: root.theme; objectName: "readerHighlightTool"; icon: "highlighter"; active: root.tool === "highlight"; tooltip: "Highlight text"; shortcut: "m"; onClicked: { root.tool = root.tool === "highlight" ? "select" : "highlight"; keys.forceActiveFocus() } }
                    // The highlighter's color; a click picks another.
                    Rectangle {
                        objectName: "readerHighlightColor"
                        implicitWidth: root.theme.space(16); implicitHeight: implicitWidth
                        Layout.rightMargin: root.theme.space(4)
                        radius: width / 2
                        color: root.highlightInk(root.highlightColor, true)
                        border.width: colorHover.hovered ? 2 : 1
                        border.color: colorHover.hovered ? root.theme.bright : root.theme.line
                        HoverHandler { id: colorHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.openColorMenu(parent) }
                        Tip { theme: root.theme; visible: colorHover.hovered; text: "Highlight color" }
                    }
                    IconButton { theme: root.theme; icon: "crop"; active: root.tool === "rect"; tooltip: "Clip a region into a note"; shortcut: "r"; onClicked: { root.tool = root.tool === "rect" ? "select" : "rect"; keys.forceActiveFocus() } }
                    IconButton { theme: root.theme; icon: "notePlus"; tooltip: "Note on this page"; shortcut: "a"; onClicked: root.composeNote(root.currentPage, null) }
                    Divider {}
                    TextField {
                        id: searchField
                        objectName: "readerSearchField"
                        visible: root.searching || root.search !== null
                        // Set, not left to Fusion's text-derived width, which
                        // loops now the controls size to their contents.
                        implicitWidth: root.theme.space(180)
                        implicitHeight: root.theme.space(26)
                        leftPadding: root.theme.space(8)
                        placeholderText: "Search this PDF"
                        placeholderTextColor: root.theme.dim
                        color: root.theme.bright
                        font.family: root.theme.sans
                        font.pixelSize: root.theme.small
                        background: Rectangle { color: root.theme.app; radius: root.theme.radiusSmall; border.width: 1; border.color: searchField.activeFocus ? root.theme.focusBorder : root.theme.line }
                        onAccepted: { root.runSearch(text); keys.forceActiveFocus() }
                        Keys.onEscapePressed: root.cancel()
                    }
                    Text {
                        visible: root.search !== null
                        Layout.leftMargin: root.theme.space(4)
                        text: root.search && root.search.flat.length ? (root.search.index + 1) + " / " + root.search.flat.length + (root.search.truncated ? "+" : "") : "0"
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                    IconButton { theme: root.theme; visible: root.search !== null; icon: "chevronUp"; tooltip: "Previous match"; shortcut: "N"; onClicked: root.showHit(-1) }
                    IconButton { theme: root.theme; visible: root.search !== null; icon: "chevronDown"; tooltip: "Next match"; shortcut: "n"; onClicked: root.showHit(1) }
                    IconButton { theme: root.theme; icon: "search"; active: root.searching; tooltip: "Search"; shortcut: "/"; onClicked: { root.searching = true; searchField.forceActiveFocus() } }
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
                SegmentedTabs {
                    Layout.fillWidth: true
                    Layout.topMargin: root.theme.space(10)
                    Layout.leftMargin: root.theme.space(18)
                    Layout.rightMargin: root.theme.space(18)
                    theme: root.theme
                    current: root.sideHighlights ? "highlights" : side.key
                    tabs: [
                        { key: "notes", label: "Notes", count: root.ref && root.ref.notes ? root.ref.notes.length : 0 },
                        { key: "highlights", label: "Highlights", count: root.highlights.length },
                        { key: "overview", label: "Abstract" },
                        { key: "ai", label: "AI summary", icon: "sparkles", visible: !!root.ref && root.app.arxivIdOf(root.ref) !== "" },
                        { key: "chat", label: "Chat", icon: "robot" }
                    ]
                    onSelected: key => {
                        if (root.app.composer) root.app.cancelComposer()
                        if (key === "highlights") root.sideHighlights = true
                        else { root.sideHighlights = false; root.app.selectTab(key) }
                    }
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
                    readonly property var sections: ["notes", "overview", "ai", "chat"]
                    readonly property string key: sections.indexOf(root.app.detailTab) >= 0 ? root.app.detailTab : "notes"
                    // The AI summary's header row would otherwise force the pane wider than it is.
                    Layout.minimumWidth: 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.sideHighlights ? sections.length : sections.indexOf(key)
                    NotesTab { theme: root.theme; app: root.app; sidePadding: root.theme.space(18) }
                    OverviewTab { theme: root.theme; app: root.app; sidePadding: root.theme.space(18) }
                    AiSummaryTab { theme: root.theme; app: root.app }
                    ChatPane { objectName: "readerChat"; theme: root.theme; app: root.app; compact: true }
                    HighlightsTab { objectName: "readerHighlights"; theme: root.theme; reader: root }
                }
            }
        }
    }

    MenuPopup {
        id: contextMenu
        objectName: "readerMenu"
        theme: root.theme
        menuWidth: root.theme.space(250)
        // What the menu acts on: {page, text, mark}.
        property var target: null
        onTriggered: key => root.runMenu(key)
    }

    Popup {
        id: highlightPopover
        objectName: "highlightPopover"
        property var mark: null
        property string heldComment: ""
        modal: true
        dim: false
        focus: true
        padding: root.theme.space(10)
        width: root.theme.space(240)
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: root.theme.raised
            border.width: 1
            border.color: root.theme.border
            radius: root.theme.radius
            Shadow { theme: root.theme; radius: parent.radius; reach: 16 }
        }
        contentItem: ColumnLayout {
            spacing: root.theme.space(8)
            focus: true
            RowLayout {
                spacing: root.theme.space(6)
                Repeater {
                    model: ["yellow", "red", "green", "purple", "blue"]
                    Rectangle {
                        id: swatch
                        required property string modelData
                        objectName: "highlightSwatch" + modelData.charAt(0).toUpperCase() + modelData.slice(1)
                        Layout.preferredWidth: root.theme.space(22)
                        Layout.preferredHeight: root.theme.space(22)
                        radius: width / 2
                        color: root.highlightInk(modelData, true)
                        border.width: highlightPopover.mark && highlightPopover.mark.color === modelData ? 2 : 1
                        border.color: highlightPopover.mark && highlightPopover.mark.color === modelData ? root.theme.bright : root.theme.line
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.setHighlightColor(swatch.modelData)
                        }
                    }
                }
            }
            TextField {
                id: commentField
                objectName: "highlightComment"
                Layout.fillWidth: true
                implicitHeight: root.theme.space(28)
                leftPadding: root.theme.space(8)
                placeholderText: "Comment"
                placeholderTextColor: root.theme.dim
                color: root.theme.bright
                font.family: root.theme.sans
                font.pixelSize: root.theme.small
                selectByMouse: true
                background: Rectangle {
                    color: root.theme.app
                    radius: root.theme.radiusSmall
                    border.width: 1
                    border.color: commentField.activeFocus ? root.theme.focusBorder : root.theme.line
                }
                onAccepted: root.saveHighlightComment(text)
                onActiveFocusChanged: if (!activeFocus) root.saveHighlightComment(text)
            }
            TextButton {
                objectName: "highlightDelete"
                theme: root.theme
                icon: "trash"
                text: "Delete"
                variant: "danger"
                Layout.alignment: Qt.AlignLeft
                onClicked: root.removeHighlight(highlightPopover.mark)
            }
        }
    }

    component Divider: Rectangle {
        implicitWidth: 1
        implicitHeight: root.theme.space(18)
        color: root.theme.line
        Layout.leftMargin: root.theme.space(4)
        Layout.rightMargin: root.theme.space(4)
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
        property bool picked: false
        property bool skipClick: false

        objectName: "readerPage" + page
        width: column.width
        height: sheetHeight


        Rectangle {
            id: sheet
            objectName: "readerSheet"
            x: Math.round((pageItem.width - pageItem.sheetWidth) / 2)
            width: pageItem.sheetWidth
            height: pageItem.sheetHeight
            color: root.app.pdfThemed ? root.theme.pageBackground : "white"
            Shadow { theme: root.theme; reach: 10; strength: 0.8 }

            Image {
                id: pageImage
                anchors.fill: parent
                // Stays visible even under theme colors: a hidden Image uploads no
                // texture for the shader to read. The shader's output is opaque.
                // Far pages drop their image so long documents don't hold every page in memory.
                source: pageItem.render && pageItem.page >= root.firstVisible - 4 && pageItem.page <= root.lastVisible + 4 ? root.app.fileUrl(pageItem.render.path) : ""
                asynchronous: true
                cache: false
                smooth: true
                mipmap: true
                retainWhileLoading: true
            }
            ShaderEffect {
                objectName: "readerPageColors"
                anchors.fill: parent
                visible: root.app.pdfThemed
                property variant source: pageImage
                property color background: root.theme.pageBackground
                property color foreground: root.theme.pageText
                property real keepHue: 1
                fragmentShader: Qt.resolvedUrl("shaders/pagecolors.frag.qsb")
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
                    var out = [], list = root.highlights
                    for (var i = 0; i < list.length; i++) {
                        if (list[i].page !== pageItem.page || !list[i].rects) continue
                        for (var j = 0; j < list[i].rects.length; j++)
                            out.push({ rect: list[i].rects[j], color: list[i].color, id: list[i].id })
                    }
                    return out
                }
                Rectangle {
                    required property var modelData
                    objectName: "readerHighlight"
                    readonly property rect box: root.fromPoints(pageItem.page, modelData.rect)
                    x: box.x; y: box.y; width: box.width; height: box.height
                    color: root.highlightInk(modelData.color, false)
                    border.width: root.focusMark === modelData.id ? 2 : 0
                    border.color: root.highlightInk(modelData.color, true)
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
                    // Under the highlighter, the ink it will leave.
                    color: root.tool === "highlight" ? root.highlightInk(root.highlightColor, false) : Qt.rgba(0.2, 0.45, 1, 0.3)
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
                    Tip {
                        theme: root.theme
                        visible: clipHover.hovered
                        text: (clipBox.modelData.body || "Clip").slice(0, 160) + "  ·  click to edit"
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
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: root.tool === "rect" ? Qt.CrossCursor
                    : root.tool === "select" && (root.linkAt(pageItem.page, mouseX, mouseY) || root.highlightAt(pageItem.page, mouseX, mouseY)) ? Qt.PointingHandCursor : Qt.IBeamCursor
                onPressed: mouse => {
                    keys.forceActiveFocus()
                    root.requestWords(pageItem.page)
                    if (mouse.button === Qt.RightButton) return
                    pageItem.pressAt = Qt.point(mouse.x, mouse.y)
                    pageItem.dragAt = pageItem.pressAt
                    pageItem.dragging = false
                    pageItem.picked = false
                }
                onPositionChanged: mouse => {
                    if (!(pressedButtons & Qt.LeftButton)) return
                    pageItem.dragAt = Qt.point(Math.max(0, Math.min(width, mouse.x)), Math.max(0, Math.min(height, mouse.y)))
                    if (Math.abs(pageItem.dragAt.x - pageItem.pressAt.x) + Math.abs(pageItem.dragAt.y - pageItem.pressAt.y) > 3) pageItem.dragging = true
                    if (pageItem.dragging && root.tool !== "rect") {
                        var from = root.wordAt(pageItem.page, pageItem.pressAt.x, pageItem.pressAt.y)
                        var to = root.wordAt(pageItem.page, pageItem.dragAt.x, pageItem.dragAt.y)
                        if (from >= 0 && to >= 0) {
                            root.selection = { page: pageItem.page, from: from, to: to }
                            pageItem.picked = true
                        }
                    }
                }
                onReleased: mouse => {
                    if (mouse.button === Qt.RightButton) { root.openMenu(pageMouse, pageItem.page, mouse.x, mouse.y); return }
                    if (pageItem.skipClick) { pageItem.skipClick = false; pageItem.dragging = false; return }
                    if (root.tool === "rect") {
                        var box = Qt.rect(Math.min(pageItem.pressAt.x, pageItem.dragAt.x), Math.min(pageItem.pressAt.y, pageItem.dragAt.y),
                                          Math.abs(pageItem.dragAt.x - pageItem.pressAt.x), Math.abs(pageItem.dragAt.y - pageItem.pressAt.y))
                        pageItem.dragging = false
                        root.composeNote(pageItem.page, box.width > 3 && box.height > 3 ? box : null)
                        return
                    }
                    if (pageItem.dragging) {
                        var picked = pageItem.picked
                        pageItem.dragging = false
                        pageItem.picked = false
                        // The highlighter keeps what it was dragged over; a plain drag only selects.
                        if (picked && root.tool === "highlight") root.highlightSelection(root.highlightColor)
                        return
                    }
                    var clip = root.clipAt(pageItem.page, mouse.x, mouse.y)
                    var link = root.linkAt(pageItem.page, mouse.x, mouse.y)
                    var mark = root.highlightAt(pageItem.page, mouse.x, mouse.y)
                    root.selection = null
                    if (clip) root.app.edit("note", clip)
                    else if (mark) root.openHighlight(mark, pageMouse, mouse.x, mouse.y)
                    else if (link && link.page) root.goToPage(link.page)
                    else if (link && link.uri) root.app.openExternal(link.uri)
                }
                onDoubleClicked: mouse => {
                    if (mouse.button !== Qt.LeftButton || root.tool === "rect") return
                    pageItem.skipClick = true
                    var w = root.wordAt(pageItem.page, mouse.x, mouse.y)
                    if (w < 0) return
                    root.selection = { page: pageItem.page, from: w, to: w }
                    if (root.tool === "highlight") root.highlightSelection(root.highlightColor)
                }
            }
        }
    }
}
