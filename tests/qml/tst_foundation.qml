import QtQuick
import QtQuick.Layouts
import QtTest
import "../../plugin/components"
import "../../plugin/components/Icons.js" as Icons

Rectangle {
    id: stage
    width: 520; height: 200
    color: ui.card
    Theme { id: ui }

    ColumnLayout {
        anchors.fill: parent; anchors.margins: 16; spacing: 12
        RowLayout {
            spacing: 4
            Repeater {
                model: ["pdf","external","notePlus","sparkles","terminal","chat","dots","library","recent","folder","alert","plus","sync","branch","command"]
                IconButton { required property string modelData; required property int index; theme: ui; icon: modelData; active: index === 3 }
            }
        }
        RowLayout {
            spacing: 8
            TextButton { id: outline; theme: ui; icon: "notePlus"; text: "New note" }
            TextButton { theme: ui; icon: "pencil"; text: "Edit BibTeX…"; variant: "ghost" }
            TextButton { theme: ui; text: "Add to library"; variant: "primary"; shortcut: "^↵" }
            TextButton { theme: ui; icon: "trash"; text: "Delete"; variant: "danger" }
        }
        RowLayout {
            spacing: 6
            Chip { theme: ui; icon: "globe"; text: "Global" }
            Chip { theme: ui; icon: "pdf"; text: "p. 4" }
            Chip { theme: ui; text: "wang_when_2026"; trailingIcon: "copy"; clickable: true }
            Chip { theme: ui; text: "Authors"; selected: true }
            Keycap { theme: ui; text: "^K" }
        }
    }

    TestCase {
        name: "Foundation"
        when: windowShown
        function test_glyphs_resolve() {
            var names = Icons.names()
            for (var i = 0; i < names.length; i++) verify(Icons.glyph(names[i]).length > 0, names[i])
            compare(Icons.glyph("nope"), "")
        }
        function test_render() {
            verify(outline.implicitWidth > 60)
            var shot = Qt.application.arguments.indexOf("-shots")
            wait(50)
            var img = grabImage(stage)
            var dir = "/tmp/omabib-qml-shots"
            img.save(dir + "/foundation.png")
        }
    }
}
