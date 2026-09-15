import QtQuick
import QtQuick.Layouts
import "Format.js" as Format
import "OverviewText.js" as OverviewText

// Abstract in a readable column, then the reference's facts.
ScrollPane {
    id: root

    required property var app
    readonly property var ref: app.selected
    readonly property var fields: ref && ref.fields ? ref.fields : ({})
    readonly property string arxiv: Format.arxivId(ref)

    SectionLabel { theme: root.theme; text: "Abstract" }

    Text {
        Layout.fillWidth: true
        visible: !!(root.ref && root.ref.abstract)
        text: root.ref ? root.ref.abstract : ""
        color: root.theme.text
        font.family: root.theme.readingFamily
        font.pixelSize: root.theme.title
        lineHeight: 1.6
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    Rectangle {
        Layout.fillWidth: true
        visible: !!root.ref && !root.ref.abstract
        implicitHeight: missing.implicitHeight + root.theme.space(28)
        color: root.theme.app
        border.width: 1
        border.color: root.theme.line
        radius: root.theme.radius
        RowLayout {
            id: missing
            anchors.fill: parent
            anchors.margins: root.theme.space(14)
            spacing: root.theme.space(10)
            Icon { theme: root.theme; name: "alert"; color: root.theme.accentText }
            Text {
                Layout.fillWidth: true
                text: "No abstract yet. Fill metadata looks it up by DOI or arXiv ID."
                color: root.theme.muted
                font.family: root.theme.mono
                font.pixelSize: root.theme.body
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            TextButton { theme: root.theme; icon: "refresh"; text: "Fill metadata"; busy: root.app.metadataBusy; onClicked: root.app.lookupMetadata() }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: root.theme.space(6)
        implicitHeight: 1
        color: root.theme.line
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 3
        columnSpacing: root.theme.space(24)
        rowSpacing: root.theme.space(14)
        Repeater {
            model: root.ref ? [
                {k: "Type", v: root.ref.entry_type || ""},
                {k: "Venue", v: Format.venue(root.ref)},
                {k: "Volume · pages", v: [root.fields.volume ? "vol. " + root.fields.volume : "", root.fields.number ? "no. " + root.fields.number : "", root.fields.pages ? "pp. " + root.fields.pages : ""].filter(function (s) { return !!s }).join(" · ")},
                {k: "DOI", v: root.fields.doi || "", url: root.fields.doi ? "https://doi.org/" + root.fields.doi : ""},
                {k: "arXiv", v: root.arxiv, url: root.arxiv ? "https://arxiv.org/abs/" + root.arxiv : ""},
                {k: "URL", v: root.fields.url && !root.fields.doi && !root.arxiv ? root.fields.url.replace(/^https?:\/\//, "") : "", url: root.fields.url || ""},
                {k: "PDF", v: root.ref.pdf_path ? Format.basename(root.ref.pdf_path) : "none linked"},
                {k: "Added", v: Format.shortDate(root.ref.created_at)},
                {k: "Citation key", v: root.ref.citekey || ""}
            ].filter(function (e) { return e.v !== "" }) : []
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: root.theme.space(3)
                SectionLabel { theme: root.theme; text: modelData.k }
                Text {
                    Layout.fillWidth: true
                    text: modelData.url ? "<a href=\"" + OverviewText.escapeHtml(modelData.url) + "\">" + OverviewText.escapeHtml(modelData.v) + "</a>" : modelData.v
                    textFormat: modelData.url ? Text.StyledText : Text.PlainText
                    color: root.theme.text
                    linkColor: root.theme.accentText
                    font.family: root.theme.mono
                    font.pixelSize: root.theme.body
                    elide: Text.ElideRight
                    onLinkActivated: link => root.app.openExternal(link)
                    HoverHandler { enabled: !!modelData.url; cursorShape: Qt.PointingHandCursor }
                }
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: !!(root.ref && root.ref.projects && root.ref.projects.length)
        spacing: root.theme.space(6)
        SectionLabel { theme: root.theme; text: "Projects" }
        Flow {
            Layout.fillWidth: true
            spacing: root.theme.space(6)
            Repeater {
                model: root.ref && root.ref.projects ? root.ref.projects : []
                Chip { required property var modelData; theme: root.theme; icon: "folder"; text: modelData.name }
            }
        }
    }
}
