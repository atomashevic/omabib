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
    readonly property bool stepsShown: app.chatStepsShown
    property string renderedDraft: ""
    property bool atBottom: true
    // What the agent is doing, shown beside the typing dots while steps are hidden.
    property string activity: ""

    // Model and effort: the chat's own, or the defaults for a new chat.
    readonly property var models: (app.chatRevision, app.chatModels[agent] || null)
    readonly property string model: chat ? (chat.chat.model || "") : (app.settings[agent + "_model"] || "")
    readonly property string effort: chat ? (chat.chat.effort || "") : (app.settings[agent + "_effort"] || "")
    readonly property var defaults: models && models.default ? models.default : ({})
    function modelEntry(id) {
        var list = models ? models.models : []
        for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
        return null
    }
    readonly property var activeModel: modelEntry(model || defaults.model || "")
    readonly property string modelLabel: {
        var id = model || defaults.model || ""
        return activeModel ? activeModel.label : id !== "" ? id : "Default model"
    }
    readonly property string effortLabel: effort || defaults.effort || (activeModel && activeModel.default_effort) || ""

    ListModel { id: transcript }

    readonly property var stepKinds: ["tool_call", "session", "note"]
    function rebuild() {
        transcript.clear()
        activity = ""
        renderedDraft = chat ? chat.draft : ""
        if (chat) for (var i = 0; i < chat.events.length; i++) add(chat.events[i])
        Qt.callLater(function () { list.positionViewAtEnd(); root.atBottom = true })
    }
    // Steps are tool calls, agent notes, and messages the agent wrote before
    // another tool call ("Let me check the PDF"). The turn's footer carries its
    // final answer for Copy and Save as note.
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
        var answer = ""
        for (var j = transcript.count - 1; j >= 0; j--) {
            var earlier = transcript.get(j)
            if (earlier.kind === "user" || earlier.kind === "turn_end") break
            if (earlier.kind !== "assistant") continue
            if (e.kind === "tool_call") transcript.setProperty(j, "step", true)
            else if (e.kind === "turn_end" && !earlier.step && answer === "") answer = JSON.parse(earlier.payload).text || ""
        }
        if (e.kind === "tool_call") activity = ChatText.toolLabel(e.data.name, e.data.input)
        else if (e.kind === "assistant") activity = ChatText.short(ChatText.plain(e.data.text), 160)
        else if (e.kind === "user" || e.kind === "turn_end") activity = ""
        transcript.append({ kind: e.kind, seq: e.seq, payload: JSON.stringify(e.data), result: "", step: root.stepKinds.indexOf(e.kind) >= 0, answer: answer })
    }
    // Rich text for an answer: Markdown, then citation and page links.
    function answerHtml(blocks, links) {
        return ChatText.linkPages(ChatText.linkCitations(Markdown.toHtml(blocks, style, app.mathCache), links, style.link), style.link)
    }
    function openModelMenu() {
        app.loadChatModels(agent)
        var list = models ? models.models : []
        var items = [{ section: "Model" }]
        var def = modelEntry(defaults.model || "")
        items.push({ key: "model:", label: "Default" + (defaults.model ? " · " + (def ? def.label : defaults.model) : ""), icon: "brain", selected: model === "" })
        for (var i = 0; i < list.length; i++) items.push({ key: "model:" + list[i].id, label: list[i].label, icon: "brain", selected: model === list[i].id })
        if (model !== "" && !modelEntry(model)) items.push({ key: "model:" + model, label: model, icon: "brain", selected: true })
        if (models && models.loading) items.push({ section: "Loading models…" })
        if (models && models.error) items.push({ section: "Couldn't list models" })
        var efforts = activeModel ? activeModel.efforts : []
        if (efforts.length) {
            items.push({ section: "Effort" })
            var defEffort = defaults.effort || activeModel.default_effort || ""
            items.push({ key: "effort:", label: "Default" + (defEffort ? " · " + defEffort : ""), icon: "speedometer", selected: effort === "" })
            for (var k = 0; k < efforts.length; k++) items.push({ key: "effort:" + efforts[k], label: efforts[k], icon: "speedometer", selected: effort === efforts[k] })
        }
        modelMenu.items = items
        modelMenu.openAt(modelChip, "left")
    }
    function chooseModel(key) {
        if (key.indexOf("model:") === 0) {
            var id = key.slice(6)
            var entry = modelEntry(id || defaults.model || "")
            // Keep the effort only where the new model supports it.
            var keep = effort !== "" && (!entry || entry.efforts.indexOf(effort) >= 0)
            app.setChatModel(agent, id, keep ? effort : "")
        } else {
            app.setChatModel(agent, model, key.slice(7))
        }
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
    onVisibleChanged: if (visible) { app.loadChatFor(ref); app.loadChatModels(agent) }
    onAgentChanged: if (visible) app.loadChatModels(agent)
    Component.onCompleted: { if (visible) { app.loadChatFor(ref); app.loadChatModels(agent) } rebuild() }

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
                // The reader's side pane is narrow: the icon, with the name in the tooltip.
                text: root.compact ? "" : root.agentLabel
                trailingIcon: root.chat && transcript.count ? "" : "chevronDown"
                clickable: !(root.chat && transcript.count)
                bordered: false
                tooltip: root.agentLabel + (root.chat && transcript.count ? " · start a new chat to switch agents" : " · chat agent")
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
            Chip {
                id: modelChip
                objectName: "chatModel"
                theme: root.theme
                maxTextWidth: root.theme.space(root.compact ? 110 : 240)
                icon: "brain"
                text: root.modelLabel + (root.effortLabel !== "" ? " · " + root.effortLabel : "")
                textColor: root.theme.muted
                trailingIcon: "chevronDown"
                clickable: true
                bordered: false
                tooltip: "Model and effort, from the next message"
                onClicked: root.openModelMenu()
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
                objectName: "chatSteps"
                theme: root.theme
                icon: "steps"
                iconColor: root.theme.muted
                active: root.stepsShown
                tooltip: root.stepsShown ? "Hide agent steps" : "Show agent steps"
                onClicked: root.app.toggleChatSteps()
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
                // Rows carry their own gap so hidden steps take no space.
                spacing: 0
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
                    required property bool step
                    required property string answer
                    readonly property bool shown: !step || root.stepsShown
                    readonly property var info: JSON.parse(payload)
                    readonly property var outcome: result ? JSON.parse(result) : null
                    width: ListView.view.width
                    height: shown && item && item.implicitHeight > 0 ? item.implicitHeight + root.theme.space(10) : 0
                    active: shown
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
                    height: root.renderedDraft !== "" || root.busy ? draftColumn.implicitHeight + root.theme.space(16) : 0
                    ColumnLayout {
                        id: draftColumn
                        x: root.theme.space(root.compact ? 12 : 24)
                        y: root.theme.space(4)
                        width: parent.width - x * 2
                        visible: root.renderedDraft !== "" || root.busy
                        spacing: root.theme.space(6)
                        ReadingText {
                            objectName: "chatDraft"
                            Layout.fillWidth: true
                            visible: root.renderedDraft !== ""
                            theme: root.theme
                            readonly property var cited: ChatText.citations(root.renderedDraft)
                            text: visible ? root.answerHtml(Markdown.blocks(cited.text), cited.links) : ""
                            onOpenLink: url => root.app.openChatLink(url)
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: root.theme.space(10)
                            visible: root.busy
                            Row {
                                spacing: root.theme.space(4)
                                Layout.alignment: Qt.AlignVCenter
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
                            Text {
                                objectName: "chatActivity"
                                Layout.fillWidth: true
                                visible: !root.stepsShown && root.activity !== "" && root.renderedDraft === ""
                                text: root.activity
                                color: root.theme.dim
                                font.family: root.theme.mono
                                font.pixelSize: root.theme.small
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
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
        id: modelMenu
        theme: root.theme
        menuWidth: root.theme.space(240)
        onTriggered: key => root.chooseModel(key)
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
            readonly property var cited: ChatText.citations(d.text || "")
            readonly property var blocks: Markdown.blocks(cited.text)
            implicitHeight: answerText.implicitHeight
            onBlocksChanged: root.app.ensureMath(Markdown.mathKeys(blocks))
            ReadingText {
                id: answerText
                objectName: "chatAnswer"
                x: root.side
                width: parent.width - root.side * 2
                theme: root.theme
                text: root.answerHtml(answer.blocks, answer.cited.links)
                onOpenLink: url => root.app.openChatLink(url)
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
            id: turn
            readonly property var d: parent ? parent.info : ({})
            readonly property string answer: parent ? parent.answer : ""
            readonly property string usage: ChatText.turnLabel(d)
            implicitHeight: answer !== "" || usage !== "" ? turnLine.implicitHeight : 0
            RowLayout {
                id: turnLine
                x: root.side
                width: parent.width - root.side * 2
                spacing: root.theme.space(2)
                TextButton { objectName: "chatCopy"; visible: turn.answer !== ""; theme: root.theme; variant: "ghost"; icon: "copy"; text: "Copy"; fontSize: root.theme.small; onClicked: root.app.copy(ChatText.plain(turn.answer)) }
                TextButton { objectName: "chatSaveNote"; visible: turn.answer !== ""; theme: root.theme; variant: "ghost"; icon: "notePlus"; text: root.compact ? "Note" : "Save as note"; fontSize: root.theme.small; onClicked: root.app.saveAnswerAsNote(ChatText.plain(turn.answer)) }
                Item { Layout.fillWidth: true }
                Text {
                    text: turn.usage
                    color: root.theme.dim
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.caption
                }
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
