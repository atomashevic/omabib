import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Markdown.js" as Markdown
import "ChatText.js" as ChatText

// A chat with Claude Code or Codex about the selected reference. App.qml owns
// the chats (`app.chats`, `app.activeChatId`) and the service calls; this pane
// keeps a transcript model it appends to as events arrive, so a streaming reply
// never rebuilds the list or drops a text selection.
FocusScope {
    id: root

    required property var theme
    required property var app
    // The reader's side pane: narrower, shorter hints.
    property bool compact: false

    readonly property var ref: app.selected
    readonly property string chatId: app.activeChatId
    readonly property var chat: (app.chatRevision, chatId ? app.chats[chatId] : null)
    // Chats are updated in place; chatRevision is what changes.
    readonly property bool busy: (app.chatRevision, !!(chat && chat.busy))
    readonly property string status: (app.chatRevision, chat ? chat.status : "")
    readonly property string agent: chat ? chat.chat.agent : app.chatAgent
    readonly property string agentLabel: agent === "codex" ? "Codex" : "Claude Code"
    readonly property var style: theme.markdownStyle(theme.app)
    readonly property bool empty: transcript.count === 0 && renderedDraft === ""
    property string renderedDraft: ""
    property bool atBottom: true

    ListModel { id: transcript }

    function rebuild() {
        transcript.clear()
        renderedDraft = chat ? chat.draft : ""
        if (chat) for (var i = 0; i < chat.events.length; i++) add(chat.events[i])
        Qt.callLater(function () { list.positionViewAtEnd(); root.atBottom = true })
    }
    function add(e) {
        if (e.kind === "tool_result" || e.kind === "approval_result") {
            var key = e.kind === "tool_result" ? "id" : "request_id"
            for (var i = transcript.count - 1; i >= 0; i--) {
                var row = transcript.get(i)
                if ((row.kind === "tool_call" || row.kind === "approval") && JSON.parse(row.payload)[key] === e.data[key]) {
                    transcript.setProperty(i, "result", JSON.stringify(e.data))
                    return
                }
            }
            return
        }
        transcript.append({ kind: e.kind, seq: e.seq, payload: JSON.stringify(e.data), result: "" })
    }
    function send() {
        var text = input.text.trim()
        if ((!text && !(app.chatAttachment && app.chatAttachment.clip)) || busy || app.chatSending) return
        app.sendChat(text)
        input.text = ""
        root.atBottom = true
    }

    Connections {
        target: root.app
        function onChatEvent(id, e) {
            if (id !== root.chatId) return
            var follow = root.atBottom
            root.add(e)
            if (e.kind === "assistant" || e.kind === "turn_end") root.renderedDraft = ""
            if (follow) Qt.callLater(function () { list.positionViewAtEnd() })
        }
        function onChatReset(id) { root.rebuild() }
        function onChatDraftChanged() { if (!draftTimer.running) draftTimer.start() }
        function onChatFocusChanged() { if (root.visible) input.forceActiveFocus() }
    }
    // Streaming Markdown is re-rendered at most every 80 ms.
    Timer {
        id: draftTimer
        interval: 80
        onTriggered: {
            root.renderedDraft = root.app.chatDraft
            if (root.atBottom) Qt.callLater(function () { list.positionViewAtEnd() })
        }
    }
    onChatIdChanged: rebuild()
    onRefChanged: if (visible) app.loadChatFor(ref)
    onVisibleChanged: if (visible) app.loadChatFor(ref)
    Component.onCompleted: { if (visible) app.loadChatFor(ref); rebuild() }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header: the agent, earlier chats, status, terminal handoff.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: root.theme.space(root.compact ? 12 : 24)
            Layout.rightMargin: root.theme.space(root.compact ? 8 : 18)
            Layout.topMargin: root.theme.space(8)
            Layout.bottomMargin: root.theme.space(6)
            spacing: root.theme.space(6)
            Chip {
                id: agentChip
                objectName: "chatAgent"
                theme: root.theme
                icon: "robot"
                iconColor: root.theme.accentText
                text: root.agentLabel
                trailingIcon: root.chat && transcript.count ? "" : "chevronDown"
                clickable: !(root.chat && transcript.count)
                bordered: false
                tooltip: root.chat && transcript.count ? "Start a new chat to switch agents" : "Chat agent"
                onClicked: {
                    var clis = (root.app.settingsInfo && root.app.settingsInfo.clis) || []
                    var available = function (id) { var c = clis.filter(function (x) { return x.id === id })[0]; return !c || c.available }
                    agentMenu.items = [
                        { key: "claude", label: "Claude Code", icon: "robot", selected: root.app.chatAgent === "claude", detail: available("claude") ? "" : "not installed" },
                        { key: "codex", label: "Codex", icon: "terminal", selected: root.app.chatAgent === "codex", detail: available("codex") ? "" : "not installed" }
                    ]
                    agentMenu.openAt(agentChip, "left")
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.busy ? (ChatText.statusLabel(root.status) || "Working…") : ""
                color: root.status === "approval" ? root.theme.accentText : root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            IconButton {
                id: historyButton
                objectName: "chatHistory"
                theme: root.theme
                icon: "history"
                iconColor: root.theme.muted
                tooltip: "Chats about this paper"
                onClicked: {
                    var chats = (root.ref && root.app.chatLists[root.ref.id]) || []
                    var items = chats.map(function (c) { return { key: c.id, label: c.title || "Untitled chat", icon: c.agent === "codex" ? "terminal" : "robot", selected: c.id === root.chatId } })
                    if (items.length) items.push({ separator: true })
                    items.push({ key: "__new", label: "New chat", icon: "plus" })
                    if (root.chatId) items.push({ key: "__delete", label: "Delete this chat", icon: "trash", danger: true })
                    historyMenu.items = items
                    historyMenu.openAt(historyButton, "right")
                    root.app.refreshChatList(root.ref)
                }
            }
            IconButton {
                theme: root.theme
                icon: "terminal"
                iconColor: root.theme.muted
                enabled: !!(root.chat && root.chat.chat.resumable)
                tooltip: "Continue in a terminal"
                onClicked: root.app.openChatInTerminal()
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.line }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: list
                objectName: "chatTranscript"
                anchors.fill: parent
                clip: true
                model: transcript
                spacing: root.theme.space(10)
                boundsBehavior: Flickable.StopAtBounds
                // Drags select text; the wheel and scroll bar scroll.
                acceptedButtons: Qt.NoButton
                topMargin: root.theme.space(12)
                bottomMargin: root.theme.space(12)
                onContentYChanged: root.atBottom = atYEnd || contentHeight <= height
                ScrollBar.vertical: ScrollBar { contentItem: Rectangle { implicitWidth: root.theme.space(4); color: root.theme.line } }

                delegate: Loader {
                    id: row
                    required property int index
                    required property string kind
                    required property string payload
                    required property string result
                    readonly property var info: JSON.parse(payload)
                    readonly property var outcome: result ? JSON.parse(result) : null
                    width: ListView.view.width
                    sourceComponent: kind === "user" ? userRow
                        : kind === "assistant" ? assistantRow
                        : kind === "tool_call" ? toolRow
                        : kind === "approval" ? approvalRow
                        : kind === "error" ? errorRow
                        : kind === "turn_end" ? turnRow
                        : quietRow
                }

                footer: Item {
                    width: list.width
                    height: root.renderedDraft !== "" || root.busy ? draftColumn.implicitHeight + root.theme.space(12) : 0
                    ColumnLayout {
                        id: draftColumn
                        x: root.theme.space(root.compact ? 12 : 24)
                        width: parent.width - x * 2
                        visible: root.renderedDraft !== "" || root.busy
                        spacing: root.theme.space(6)
                        ReadingText {
                            objectName: "chatDraft"
                            Layout.fillWidth: true
                            visible: root.renderedDraft !== ""
                            theme: root.theme
                            readonly property var blocks: Markdown.blocks(root.renderedDraft)
                            text: visible ? ChatText.linkPages(Markdown.toHtml(blocks, root.style, root.app.mathCache), root.style.link) : ""
                            onOpenLink: url => root.app.openChatLink(url)
                        }
                        Row {
                            spacing: root.theme.space(4)
                            visible: root.busy
                            Repeater {
                                model: 3
                                Rectangle {
                                    required property int index
                                    width: root.theme.space(5); height: width; radius: width / 2
                                    color: root.theme.dim
                                    SequentialAnimation on opacity {
                                        loops: Animation.Infinite
                                        PauseAnimation { duration: index * 150 }
                                        NumberAnimation { from: 0.25; to: 1; duration: 350 }
                                        NumberAnimation { from: 1; to: 0.25; duration: 350 }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            EmptyState {
                theme: root.theme
                anchors.centerIn: parent
                width: Math.min(parent.width - root.theme.space(32), root.theme.space(420))
                visible: root.empty && !root.busy
                icon: "robot"
                title: "Ask " + root.agentLabel + " about this paper"
                hint: "It reads the paper, your notes and clips. Reading is free; saving notes, running commands or going online asks you first."
            }
        }

        // Composer.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: root.theme.space(root.compact ? 10 : 24)
            Layout.rightMargin: root.theme.space(root.compact ? 10 : 18)
            Layout.bottomMargin: root.theme.space(10)
            spacing: root.theme.space(6)

            Text {
                Layout.fillWidth: true
                visible: root.app.chatError !== ""
                text: root.app.chatError
                color: root.theme.urgent
                font.family: root.theme.mono
                font.pixelSize: root.theme.small
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }

            Rectangle {
                objectName: "chatAttachment"
                Layout.fillWidth: true
                visible: !!root.app.chatAttachment
                implicitHeight: attachmentRow.implicitHeight + root.theme.space(12)
                color: root.theme.app
                radius: root.theme.radius
                border.width: 1
                border.color: root.theme.line
                readonly property var a: root.app.chatAttachment || ({})
                RowLayout {
                    id: attachmentRow
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(8); rightMargin: root.theme.space(4) }
                    spacing: root.theme.space(8)
                    Icon { theme: root.theme; name: parent.parent.a.clip ? "crop" : "quote"; size: root.theme.title; color: root.theme.accentText }
                    Image {
                        visible: !!(parent.parent.a.clip && parent.parent.a.clip.preview)
                        Layout.preferredHeight: root.theme.space(36)
                        Layout.preferredWidth: root.theme.space(60)
                        fillMode: Image.PreserveAspectFit
                        source: visible ? root.app.fileUrl(parent.parent.a.clip.preview.path) : ""
                        sourceClipRect: visible ? parent.parent.a.clip.preview.rect : Qt.rect(0, 0, 0, 0)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: parent.parent.a.clip ? "Region of p. " + parent.parent.a.clip.page
                            : parent.parent.a.selection ? "p. " + parent.parent.a.selection.page + " · “" + ChatText.short(parent.parent.a.selection.text, 140) + "”" : ""
                        color: root.theme.muted
                        font.family: root.theme.readingFamily
                        font.pixelSize: root.theme.small
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                    }
                    IconButton { theme: root.theme; icon: "close"; size: root.theme.space(22); iconSize: root.theme.body; iconColor: root.theme.dim; tooltip: "Remove"; onClicked: root.app.chatAttachment = null }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: Math.min(root.theme.space(180), input.implicitHeight) + root.theme.space(8)
                color: root.theme.app
                radius: root.theme.radius
                border.width: input.activeFocus ? root.theme.focusBorderWidth : 1
                border.color: input.activeFocus ? root.theme.focusBorder : root.theme.controlBorder
                RowLayout {
                    anchors { fill: parent; leftMargin: root.theme.space(4); rightMargin: root.theme.space(4) }
                    spacing: root.theme.space(4)
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        TextArea {
                            id: input
                            objectName: "chatInput"
                            placeholderText: root.busy ? root.agentLabel + " is replying…" : "Ask " + root.agentLabel + " about this paper…"
                            placeholderTextColor: root.theme.dim
                            color: root.theme.bright
                            selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.55)
                            selectedTextColor: root.theme.bright
                            font.family: root.theme.readingFamily
                            font.pixelSize: root.theme.subtitle
                            wrapMode: TextEdit.Wrap
                            selectByMouse: true
                            background: Item {}
                            Keys.onPressed: event => {
                                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                                    root.send()
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Escape) {
                                    root.app.focusActiveTab()
                                    event.accepted = true
                                }
                            }
                        }
                    }
                    IconButton {
                        objectName: root.busy ? "chatStop" : "chatSend"
                        Layout.alignment: Qt.AlignBottom
                        Layout.bottomMargin: root.theme.space(2)
                        theme: root.theme
                        icon: root.busy ? "stop" : "send"
                        iconColor: root.busy ? root.theme.urgent : root.theme.accentText
                        busy: root.app.chatSending
                        enabled: root.busy || input.text.trim() !== "" || !!(root.app.chatAttachment && root.app.chatAttachment.clip)
                        tooltip: root.busy ? "Stop" : "Send"
                        shortcut: root.busy ? "" : "Enter"
                        onClicked: root.busy ? root.app.cancelChat() : root.send()
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: !root.compact
                text: "Enter sends · Shift+Enter adds a line · pages like “p. 7” open in the reader"
                color: root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: root.theme.caption
                elide: Text.ElideRight
            }
        }
    }

    MenuPopup {
        id: agentMenu
        theme: root.theme
        menuWidth: root.theme.space(200)
        onTriggered: key => { root.app.chatAgent = key; if (root.chatId && transcript.count === 0) root.app.newChat() }
    }
    MenuPopup {
        id: historyMenu
        theme: root.theme
        menuWidth: root.theme.space(280)
        onTriggered: key => {
            if (key === "__new") root.app.newChat()
            else if (key === "__delete") root.app.deleteActiveChat()
            else root.app.openChat(key)
        }
    }

    // ---- Rows ----

    readonly property real side: theme.space(compact ? 12 : 24)

    Component {
        id: userRow
        Item {
            readonly property var d: parent ? parent.info : ({})
            implicitHeight: userCard.implicitHeight
            Rectangle {
                id: userCard
                x: root.side
                width: parent.width - root.side * 2
                implicitHeight: userColumn.implicitHeight + root.theme.space(16)
                color: root.theme.line
                radius: root.theme.radius
                ColumnLayout {
                    id: userColumn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(8); leftMargin: root.theme.space(12) }
                    spacing: root.theme.space(6)
                    Text {
                        Layout.fillWidth: true
                        visible: !!d.selection
                        text: d.selection ? "p. " + d.selection.page + " · “" + ChatText.short(d.selection.text, 240) + "”" : ""
                        color: root.theme.muted
                        font.family: root.theme.readingFamily
                        font.pixelSize: root.theme.small
                        font.italic: true
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Image {
                        visible: !!(d.clip && d.clip.file)
                        Layout.maximumWidth: parent.width
                        Layout.preferredHeight: Math.min(root.theme.space(140), implicitHeight)
                        fillMode: Image.PreserveAspectFit
                        horizontalAlignment: Image.AlignLeft
                        source: visible ? root.app.fileUrl(d.clip.file) : ""
                        asynchronous: true
                    }
                    ReadingText {
                        Layout.fillWidth: true
                        visible: !!d.text
                        theme: root.theme
                        color: root.theme.bright
                        text: d.text ? "<p style=\"margin:0; line-height:150%\">" + Markdown.escapeHtml(d.text).replace(/\n/g, "<br>") + "</p>" : ""
                    }
                }
            }
        }
    }

    Component {
        id: assistantRow
        Item {
            id: answer
            readonly property var d: parent ? parent.info : ({})
            readonly property var blocks: Markdown.blocks(d.text || "")
            implicitHeight: answerColumn.implicitHeight
            onBlocksChanged: root.app.ensureMath(Markdown.mathKeys(blocks))
            HoverHandler { id: answerHover }
            ColumnLayout {
                id: answerColumn
                x: root.side
                width: parent.width - root.side * 2
                spacing: root.theme.space(2)
                ReadingText {
                    objectName: "chatAnswer"
                    Layout.fillWidth: true
                    theme: root.theme
                    text: ChatText.linkPages(Markdown.toHtml(answer.blocks, root.style, root.app.mathCache), root.style.link)
                    onOpenLink: url => root.app.openChatLink(url)
                }
                RowLayout {
                    spacing: root.theme.space(2)
                    opacity: answerHover.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    TextButton { theme: root.theme; variant: "ghost"; icon: "copy"; text: "Copy"; fontSize: root.theme.small; onClicked: root.app.copy(answer.d.text) }
                    TextButton { theme: root.theme; variant: "ghost"; icon: "notePlus"; text: "Save as note"; fontSize: root.theme.small; onClicked: root.app.saveAnswerAsNote(answer.d.text) }
                }
            }
        }
    }

    Component {
        id: toolRow
        Item {
            id: tool
            readonly property var d: parent ? parent.info : ({})
            readonly property var outcome: parent ? parent.outcome : null
            property bool expanded: false
            implicitHeight: toolColumn.implicitHeight
            ColumnLayout {
                id: toolColumn
                x: root.side
                width: parent.width - root.side * 2
                spacing: root.theme.space(4)
                RowLayout {
                    Layout.fillWidth: true
                    spacing: root.theme.space(8)
                    Icon { theme: root.theme; name: ChatText.toolIcon(tool.d.name); size: root.theme.body + 1; color: root.theme.dim }
                    Text {
                        Layout.fillWidth: true
                        text: ChatText.toolLabel(tool.d.name, tool.d.input)
                        color: root.theme.muted
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Icon {
                        theme: root.theme
                        name: !tool.outcome ? "refresh" : tool.outcome.is_error ? "alert" : "check"
                        size: root.theme.body
                        color: tool.outcome && tool.outcome.is_error ? root.theme.urgent : root.theme.dim
                        visible: !!tool.outcome || root.busy
                        RotationAnimation on rotation { running: !tool.outcome && root.busy; from: 0; to: 360; duration: 900; loops: Animation.Infinite }
                    }
                    Icon { theme: root.theme; visible: !!(tool.outcome && tool.outcome.output); name: tool.expanded ? "chevronDown" : "chevronRight"; size: root.theme.body; color: root.theme.dim }
                    TapHandler { onTapped: if (tool.outcome && tool.outcome.output) tool.expanded = !tool.expanded }
                    HoverHandler { cursorShape: tool.outcome && tool.outcome.output ? Qt.PointingHandCursor : Qt.ArrowCursor }
                }
                Rectangle {
                    Layout.fillWidth: true
                    visible: tool.expanded
                    implicitHeight: output.implicitHeight + root.theme.space(12)
                    color: root.theme.app
                    border.width: 1
                    border.color: root.theme.line
                    radius: root.theme.radius
                    TextEdit {
                        id: output
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(6) }
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.WrapAnywhere
                        text: tool.outcome ? tool.outcome.output : ""
                        color: tool.outcome && tool.outcome.is_error ? root.theme.urgent : root.theme.text
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        textFormat: TextEdit.PlainText
                    }
                }
            }
        }
    }

    Component {
        id: approvalRow
        Item {
            id: approval
            readonly property var d: parent ? parent.info : ({})
            readonly property var outcome: parent ? parent.outcome : null
            readonly property var summary: ChatText.approvalSummary(d.tool, d.input, root.agentLabel)
            readonly property bool pending: !outcome
            implicitHeight: card.implicitHeight
            Rectangle {
                id: card
                objectName: "chatApproval"
                x: root.side
                width: parent.width - root.side * 2
                implicitHeight: approvalColumn.implicitHeight + root.theme.space(20)
                color: root.theme.app
                radius: root.theme.radius
                border.width: approval.pending ? 2 : 1
                border.color: approval.pending ? root.theme.accent : root.theme.line
                ColumnLayout {
                    id: approvalColumn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(10); leftMargin: root.theme.space(12) }
                    spacing: root.theme.space(6)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.theme.space(8)
                        Icon { theme: root.theme; name: "alert"; size: root.theme.title; color: approval.pending ? root.theme.accentText : root.theme.dim }
                        Text {
                            Layout.fillWidth: true
                            text: approval.summary.title
                            color: root.theme.bright
                            font.family: root.theme.readingFamily
                            font.pixelSize: root.theme.body
                            font.weight: Font.Medium
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: approval.summary.detail !== ""
                        text: approval.summary.detail
                        color: root.theme.text
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 8
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    RowLayout {
                        visible: approval.pending
                        spacing: root.theme.space(8)
                        TextButton { objectName: "chatAllow"; theme: root.theme; variant: "primary"; icon: "check"; text: "Allow once"; onClicked: root.app.approveChat(approval.d.request_id, true) }
                        TextButton { objectName: "chatDeny"; theme: root.theme; variant: "ghost"; icon: "close"; text: "Deny"; onClicked: root.app.approveChat(approval.d.request_id, false) }
                    }
                    Text {
                        visible: !approval.pending
                        text: !approval.outcome ? "" : approval.outcome.allow ? "Allowed" : approval.outcome.reason === "expired" ? "Expired, not allowed" : "Declined"
                        color: approval.outcome && approval.outcome.allow ? root.theme.accentText : root.theme.dim
                        font.family: root.theme.mono
                        font.pixelSize: root.theme.small
                    }
                }
            }
        }
    }

    Component {
        id: errorRow
        Item {
            readonly property var d: parent ? parent.info : ({})
            implicitHeight: errorLine.implicitHeight
            RowLayout {
                id: errorLine
                x: root.side
                width: parent.width - root.side * 2
                spacing: root.theme.space(8)
                Icon { theme: root.theme; name: "alert"; size: root.theme.body + 1; color: root.theme.urgent; Layout.alignment: Qt.AlignTop }
                Text {
                    Layout.fillWidth: true
                    text: parent.parent.d.message || ""
                    color: root.theme.urgent
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.small
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
            }
        }
    }

    Component {
        id: turnRow
        Item {
            readonly property var d: parent ? parent.info : ({})
            implicitHeight: turnText.text !== "" ? turnText.implicitHeight : 0
            Text {
                id: turnText
                x: root.side
                width: parent.width - root.side * 2
                text: ChatText.turnLabel(parent.d)
                horizontalAlignment: Text.AlignRight
                color: root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: root.theme.caption
            }
        }
    }

    Component {
        id: quietRow
        Item {
            readonly property var d: parent ? parent.info : ({})
            readonly property string kind: parent ? parent.kind : ""
            implicitHeight: quietText.implicitHeight
            Text {
                id: quietText
                x: root.side
                width: parent.width - root.side * 2
                text: parent.kind === "session" ? [parent.d.agent === "codex" ? "Codex" : "Claude Code", parent.d.version, parent.d.model].filter(function (s) { return !!s }).join(" · ") : (parent.d.message || "")
                color: root.theme.dim
                font.family: root.theme.mono
                font.pixelSize: root.theme.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }
    }
}
