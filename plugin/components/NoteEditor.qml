import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Markdown.js" as Markdown

// The note editor with inline live preview: the note renders block by block,
// and only the block being edited shows its Markdown source. `text` is always
// the whole note.
//
// The source is split into three parts around the active block: the lines
// before it and after it render as Markdown, the active lines sit in a
// TextArea. Typing only changes the middle, so the rendered parts stay put
// until another block is activated.
FocusScope {
    id: root

    required property var theme
    required property var app
    property string text: ""
    property string placeholderText: ""
    property bool toolbar: true

    readonly property bool editing: area.activeFocus
    readonly property var style: theme.markdownStyle(theme.card)

    // Source lines [activeStart, activeStart + activeLines) are in the TextArea.
    property int activeStart: 0
    readonly property int activeLines: area.text.split("\n").length
    property string beforeText: ""
    property string afterText: ""
    property bool hasBefore: false
    property bool hasAfter: false
    property bool syncing: false

    readonly property var beforeBlocks: hasBefore ? Markdown.blocks(beforeText) : []
    readonly property var afterBlocks: hasAfter ? Markdown.blocks(afterText) : []
    // Code and math blocks are edited in the monospace face.
    readonly property bool sourceBlock: /^(```|~~~|\$\$|\\\[)/.test(area.text.trim())
    readonly property var activeBlocks: Markdown.blocks(area.text)
    readonly property bool activeHasMath: Markdown.mathKeys(activeBlocks).length > 0

    onTextChanged: if (!syncing) reset()
    onBeforeBlocksChanged: app.ensureMath(Markdown.mathKeys(beforeBlocks))
    onAfterBlocksChanged: app.ensureMath(Markdown.mathKeys(afterBlocks))
    Component.onCompleted: reset()

    // Opens a note with its last block active and the cursor at the end.
    function reset() {
        var blocks = Markdown.blocks(text)
        var last = text.split("\n").length - 1
        if (blocks.length) activate(blocks[blocks.length - 1].start, blocks[blocks.length - 1].end, -1, false)
        else activate(last, last, -1, false)
    }

    function setTextQuietly(value) {
        syncing = true
        text = value
        syncing = false
    }

    // Make source lines [start, end] the active block; cursor < 0 means its end.
    function activate(start, end, cursor, focus) {
        var lines = text.split("\n")
        start = Math.max(0, Math.min(start, lines.length - 1))
        end = Math.max(start, Math.min(end, lines.length - 1))
        syncing = true
        beforeText = lines.slice(0, start).join("\n")
        hasBefore = start > 0
        afterText = lines.slice(end + 1).join("\n")
        hasAfter = end + 1 < lines.length
        activeStart = start
        area.text = lines.slice(start, end + 1).join("\n")
        syncing = false
        area.cursorPosition = cursor < 0 ? area.length : Math.min(cursor, area.length)
        if (focus !== false) area.forceActiveFocus()
    }

    function previousBlock() {
        return beforeBlocks.length ? beforeBlocks[beforeBlocks.length - 1] : null
    }
    function nextBlock() {
        var b = afterBlocks.length ? afterBlocks[0] : null
        var offset = activeStart + activeLines
        return b ? { start: b.start + offset, end: b.end + offset } : null
    }

    // A click on a rendered block: activate it with the cursor near the
    // clicked character, found by matching the text just before it in the source.
    function activateAt(start, end, doc, x, y) {
        var source = text.split("\n").slice(start, end + 1).join("\n")
        var pos = doc.positionAt(x, y)
        var plain = doc.getText(0, doc.length)
        Qt.callLater(activate, start, end, sourceOffset(source, plain, pos))
    }
    function sourceOffset(source, plain, pos) {
        if (pos <= 0) return 0
        var guess = Math.round(source.length * pos / Math.max(1, plain.length))
        // Paragraph breaks and images have no counterpart in the source.
        var tail = plain.slice(Math.max(0, pos - 16), pos).split(/[\u2029\uFFFC\n]/).pop()
        for (var n = tail.length; n >= 2; n--) {
            var snip = tail.slice(tail.length - n)
            var best = -1
            for (var at = source.indexOf(snip); at >= 0; at = source.indexOf(snip, at + 1)) {
                if (best < 0 || Math.abs(at + n - guess) < Math.abs(best + n - guess)) best = at
            }
            if (best >= 0) return best + n
        }
        return Math.min(guess, source.length)
    }

    // Close the active block after its last line and start an empty one.
    function startBlockAfter() {
        var lines = text.split("\n")
        var end = activeStart + activeLines - 1
        if (end + 1 >= lines.length || lines[end + 1].trim() !== "") lines.splice(end + 1, 0, "")
        var next = end + 2
        if (next >= lines.length || lines[next].trim() !== "") lines.splice(next, 0, "")
        if (next + 1 < lines.length && lines[next + 1].trim() !== "") lines.splice(next + 1, 0, "")
        setTextQuietly(lines.join("\n"))
        activate(next, next, 0)
    }

    function onFirstLine() {
        return area.positionToRectangle(area.cursorPosition).y <= area.positionToRectangle(0).y + 1
    }
    function onLastLine() {
        return area.positionToRectangle(area.cursorPosition).y >= area.positionToRectangle(area.length).y - 1
    }

    function handleKey(event) {
        var plain = (event.modifiers & ~Qt.KeypadModifier) === Qt.NoModifier
        if (!plain) return
        if (event.key === Qt.Key_Up && onFirstLine()) {
            var prev = previousBlock()
            if (!prev) return
            var x = area.cursorRectangle.x
            event.accepted = true
            activate(prev.start, prev.end, -1)
            var r = area.positionToRectangle(area.length)
            area.cursorPosition = area.positionAt(x, r.y + r.height / 2)
        } else if (event.key === Qt.Key_Down && onLastLine()) {
            var next = nextBlock()
            if (!next) return
            var x2 = area.cursorRectangle.x
            event.accepted = true
            activate(next.start, next.end, 0)
            var r2 = area.positionToRectangle(0)
            area.cursorPosition = area.positionAt(x2, r2.y + r2.height / 2)
        } else if (event.key === Qt.Key_Backspace && area.cursorPosition === 0 && area.selectedText === "" && hasBefore) {
            var before = previousBlock()
            var from = before ? before.start : 0
            var lines = text.split("\n")
            var join = lines.slice(from, activeStart).join("\n").length + 1
            event.accepted = true
            activate(from, activeStart + activeLines - 1, join)
            area.remove(join - 1, join)
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && area.selectedText === "") {
            var cursor = area.cursorPosition
            if (cursor < area.length && area.text.charAt(cursor) !== "\n") return
            // Inside a code or math block Enter is just a newline; after its
            // closing fence it behaves as after any other block.
            var cursorLine = area.text.slice(0, cursor).split("\n").length - 1
            var within = activeBlocks.filter(function (b) { return b.start <= cursorLine && cursorLine <= b.end })[0]
            if (within && (within.type === "code" || within.type === "math")) return
            var lineStart = area.text.lastIndexOf("\n", cursor - 1) + 1
            var line = area.text.slice(lineStart, cursor)
            var item = /^(\s*)([-*+]|(\d+)([.)]))(\s+)(.*)$/.exec(line)
            if (item && item[6] !== "") {
                event.accepted = true
                var marker = item[3] !== undefined ? (Number(item[3]) + 1) + item[4] : item[2]
                area.insert(cursor, "\n" + item[1] + marker + item[5])
            } else if (item || (line === "" && cursor === area.length && cursor > 0)) {
                // An empty list item or a second Enter ends the block.
                event.accepted = true
                area.remove(Math.max(0, lineStart - 1), cursor)
                startBlockAfter()
            }
        }
    }

    // Toolbar: wrap the selection, or insert a placeholder and select it.
    function wrap(prefix, suffix, placeholder) {
        var s = area.selectionStart, e = area.selectionEnd
        var inner = area.text.slice(s, e) || placeholder
        area.remove(s, e)
        area.insert(s, prefix + inner + suffix)
        area.select(s + prefix.length, s + prefix.length + inner.length)
        area.forceActiveFocus()
    }
    function prefixLine(prefix) {
        var at = area.text.lastIndexOf("\n", area.selectionStart - 1) + 1
        area.insert(at, prefix)
        area.forceActiveFocus()
    }
    // Inline span, or a fenced block when the selection spans lines or the line is empty.
    function codeOrMath(fence, inline, placeholder) {
        var s = area.selectionStart, e = area.selectionEnd
        var lineStart = area.text.lastIndexOf("\n", s - 1) + 1
        var lineEnd = area.text.indexOf("\n", e)
        var line = area.text.slice(lineStart, lineEnd < 0 ? area.length : lineEnd)
        if (area.text.slice(s, e).indexOf("\n") >= 0 || line.trim() === "") wrap(fence + "\n", "\n" + fence, placeholder)
        else wrap(inline, inline, placeholder)
    }

    Timer {
        id: previewMath
        interval: 350
        onTriggered: root.app.ensureMath(Markdown.mathKeys(root.activeBlocks))
    }

    component Rendered: Item {
        id: block
        objectName: "noteEditorBlock"
        required property var modelData
        property int offset: 0
        Layout.fillWidth: true
        implicitHeight: doc.implicitHeight
        ReadingText {
            id: doc
            width: parent.width
            theme: root.theme
            text: Markdown.toHtml([block.modelData], root.style, root.app.mathCache)
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: mouse => {
                var link = doc.linkAt(mouse.x, mouse.y)
                if (link && (mouse.modifiers & Qt.ControlModifier)) root.app.openExternal(link)
                else root.activateAt(block.modelData.start + block.offset, block.modelData.end + block.offset, doc, mouse.x, mouse.y)
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: root.theme.space(6)

        RowLayout {
            visible: root.toolbar
            Layout.fillWidth: true
            spacing: root.theme.space(2)
            IconButton { theme: root.theme; icon: "heading"; tooltip: "Heading"; iconSize: root.theme.title; onClicked: root.prefixLine("## ") }
            IconButton { theme: root.theme; icon: "bold"; tooltip: "Bold"; iconSize: root.theme.title; onClicked: root.wrap("**", "**", "bold") }
            IconButton { theme: root.theme; icon: "italic"; tooltip: "Italic"; iconSize: root.theme.title; onClicked: root.wrap("*", "*", "italic") }
            IconButton { theme: root.theme; icon: "quote"; tooltip: "Quote"; iconSize: root.theme.title; onClicked: root.prefixLine("> ") }
            IconButton { theme: root.theme; icon: "list"; tooltip: "List"; iconSize: root.theme.title; onClicked: root.prefixLine("- ") }
            IconButton { theme: root.theme; icon: "code"; tooltip: "Code · a block on an empty line"; iconSize: root.theme.title; onClicked: root.codeOrMath("```", "`", "code") }
            IconButton { theme: root.theme; icon: "math"; tooltip: "Math · a block on an empty line"; iconSize: root.theme.title; onClicked: root.codeOrMath("$$", "$", "x") }
            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideLeft
                text: "Markdown  ·  $…$ math  ·  ``` code"
                color: root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                textFormat: Text.PlainText
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.theme.app
            radius: root.theme.radius
            border.width: area.activeFocus ? root.theme.focusBorderWidth : 1
            border.color: area.activeFocus ? root.theme.focusBorder : root.theme.line

            Flickable {
                id: flick
                objectName: "noteEditorFlick"
                anchors.fill: parent
                anchors.margins: root.theme.space(12)
                clip: true
                contentWidth: width
                contentHeight: Math.max(height, column.implicitHeight)
                boundsBehavior: Flickable.StopAtBounds
                // Mouse drags select text; the wheel and scroll bar scroll.
                acceptedButtons: Qt.NoButton
                flickableDirection: Flickable.VerticalFlick

                function ensureVisible(r) {
                    var y = area.mapToItem(column, 0, r.y).y
                    if (y < contentY) contentY = y
                    else if (y + r.height > contentY + height) contentY = y + r.height - height
                }

                // Clicks below the last block continue at the end of the note.
                MouseArea {
                    width: flick.width
                    height: flick.contentHeight
                    cursorShape: Qt.IBeamCursor
                    onClicked: {
                        var lines = root.text.split("\n")
                        var blocks = Markdown.blocks(root.text)
                        var last = blocks.length ? blocks[blocks.length - 1] : { start: lines.length - 1, end: lines.length - 1 }
                        root.activate(last.start, last.end, -1)
                    }
                }

                ColumnLayout {
                    id: column
                    // Room on the left for the active block's marker.
                    x: root.theme.space(10)
                    width: flick.width - x - root.theme.space(8)
                    spacing: root.theme.space(4)

                    Repeater {
                        model: root.beforeBlocks
                        delegate: Rendered {}
                    }

                    Item {
                        Layout.fillWidth: true
                        implicitHeight: area.implicitHeight
                        Rectangle {
                            x: -root.theme.space(8)
                            width: 2
                            height: parent.height
                            color: root.theme.accent
                            opacity: area.activeFocus ? 0.8 : 0.3
                        }
                        TextArea {
                            id: area
                            objectName: "noteEditorArea"
                            width: parent.width
                            focus: true
                            padding: 0
                            background: null
                            color: root.theme.bright
                            placeholderText: root.text === "" ? root.placeholderText : ""
                            placeholderTextColor: root.theme.dim
                            selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.55)
                            selectedTextColor: root.theme.bright
                            font.family: root.sourceBlock ? root.theme.mono : root.theme.readingFamily
                            font.pixelSize: root.sourceBlock ? root.theme.body : root.theme.title
                            wrapMode: TextEdit.Wrap
                            selectByMouse: true
                            textFormat: TextEdit.PlainText
                            Keys.onPressed: event => root.handleKey(event)
                            onTextChanged: {
                                if (root.activeHasMath) previewMath.restart()
                                if (root.syncing) return
                                root.syncing = true
                                root.text = (root.hasBefore ? root.beforeText + "\n" : "") + text + (root.hasAfter ? "\n" + root.afterText : "")
                                root.syncing = false
                            }
                            onCursorRectangleChanged: if (activeFocus) flick.ensureVisible(cursorRectangle)
                        }
                    }

                    // The active block's math, rendered while its source is edited.
                    Rectangle {
                        visible: root.activeHasMath
                        Layout.fillWidth: true
                        implicitHeight: preview.implicitHeight + root.theme.space(12)
                        color: root.theme.card
                        radius: root.theme.radius
                        ReadingText {
                            id: preview
                            objectName: "noteEditorMathPreview"
                            x: root.theme.space(8); y: root.theme.space(6)
                            width: parent.width - root.theme.space(16)
                            theme: root.theme
                            text: root.activeHasMath ? Markdown.toHtml(root.activeBlocks, root.style, root.app.mathCache) : ""
                        }
                    }

                    Repeater {
                        model: root.afterBlocks
                        delegate: Rendered { offset: root.activeStart + root.activeLines }
                    }
                }

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    contentItem: Rectangle { implicitWidth: root.theme.space(4); color: root.theme.line }
                }
            }
        }
    }
}
