import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "OverviewText.js" as OverviewText

ScrollPane {
    id: root

    required property var app
    readonly property var ref: app.selected

    function highlight(bib) {
        var dim = root.theme.dim.toString(), muted = root.theme.muted.toString()
        var accent = root.theme.accentText.toString(), bright = root.theme.bright.toString()
        var lines = String(bib || "").split("\n")
        return lines.map(function (line) {
            var head = /^@(\w+)\{([^,]*),\s*$/.exec(line)
            if (head)
                return "<font color=\"" + accent + "\">@" + OverviewText.escapeHtml(head[1]) + "</font><font color=\"" + dim + "\">{</font><font color=\"" + bright + "\">" + OverviewText.escapeHtml(head[2]) + "</font><font color=\"" + dim + "\">,</font>"
            var field = /^(\s*)([\w-]+)(\s*=\s*)(.*)$/.exec(line)
            if (field)
                return "&nbsp;&nbsp;<font color=\"" + muted + "\">" + OverviewText.escapeHtml(field[2]) + "</font><font color=\"" + dim + "\">" + OverviewText.escapeHtml(field[3]) + "</font>" + OverviewText.escapeHtml(field[4])
            return "<font color=\"" + dim + "\">" + OverviewText.escapeHtml(line) + "</font>"
        }).join("<br>")
    }

    measure: theme.space(780)

    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(8)
        TextButton { theme: root.theme; icon: "copy"; text: "Key"; onClicked: root.app.copyFormat("key") }
        TextButton { theme: root.theme; icon: "copy"; text: "\\cite{…}"; onClicked: root.app.copyFormat("latex") }
        TextButton { theme: root.theme; icon: "copy"; text: "[@…]"; onClicked: root.app.copyFormat("pandoc") }
        TextButton { theme: root.theme; icon: "copy"; text: "BibTeX"; onClicked: root.app.copyFormat("bibtex") }
        Item { Layout.fillWidth: true }
        TextButton { theme: root.theme; variant: "ghost"; icon: "pencil"; text: "Edit BibTeX…"; onClicked: root.app.edit("metadata", null) }
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: code.implicitHeight + root.theme.space(28)
        color: root.theme.app
        border.width: 1
        border.color: root.theme.line
        radius: root.theme.radius
        TextEdit {
            id: code
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.theme.space(14); leftMargin: root.theme.space(16) }
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
            textFormat: TextEdit.RichText
            text: "<div style=\"line-height:150%\">" + root.highlight(root.ref ? root.ref.bibtex : "") + "</div>"
            color: root.theme.text
            selectionColor: Qt.rgba(root.theme.accent.r, root.theme.accent.g, root.theme.accent.b, 0.55)
            selectedTextColor: root.theme.bright
            font.family: root.theme.mono
            font.pixelSize: root.theme.body
        }
    }
}
