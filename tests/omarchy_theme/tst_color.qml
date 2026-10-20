import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import "../../plugin/components"

// Offscreen check for the Omarchy palette. HOME is a temp directory, and the
// theme file is a fixture. Nothing here talks to a real library or account.
Rectangle {
    id: stage
    width: 80
    height: 80
    color: ui.app

    Theme { id: ui; mode: "omarchy" }

    Rectangle {
        id: swatch
        objectName: "omarchySwatch"
        anchors.centerIn: parent
        width: 40
        height: 40
        color: ui.accent
    }

    Process { id: py }
    SignalSpy { id: pyExited; target: py; signalName: "exited" }

    TestCase {
        name: "OmarchyTheme"
        when: windowShown

        function hexByte(n) {
            var s = Math.round(n * 255).toString(16)
            return s.length < 2 ? "0" + s : s
        }

        function hex(c) {
            var x = Qt.color(c)
            return "#" + hexByte(x.r) + hexByte(x.g) + hexByte(x.b)
        }

        function runPy(code) {
            pyExited.clear()
            py.command = ["python3", "-c", code]
            py.running = true
            pyExited.wait(10000)
            compare(pyExited.count, 1, "python did not exit")
            compare(pyExited.signalArguments[0][0], 0, code)
        }

        // The same swap omarchy-theme-set does: remove the theme directory, then
        // move a prepared directory into its place.
        function replaceTheme(toml) {
            var code = "import shutil, pathlib, os\n" +
                "current = pathlib.Path(os.environ['HOME']) / '.local/state/omarchy/current'\n" +
                "theme = current / 'theme'\n" +
                "prepared = current / 'theme.next'\n" +
                "shutil.rmtree(prepared, ignore_errors=True)\n" +
                "prepared.mkdir()\n" +
                "(prepared / 'colors.toml').write_text(" + JSON.stringify(toml) + ")\n" +
                "shutil.rmtree(theme)\n" +
                "prepared.rename(theme)\n"
            runPy(code)
        }

        function writeColors(toml) {
            var code = "import pathlib, os\n" +
                "path = pathlib.Path(os.environ['HOME']) / '.local/state/omarchy/current/theme/colors.toml'\n" +
                "path.write_text(" + JSON.stringify(toml) + ")\n"
            runPy(code)
        }

        function test_follow_and_switch() {
            tryVerify(function() { return Color.omarchyTheme === true && hex(Color.accent) === "#aa3300" }, 5000)
            compare(Color.mode, "dark")
            compare(hex(Color.background), "#f4f1ea")
            compare(hex(Color.foreground), "#1c1915")
            compare(hex(Color.urgent), "#cc2211")
            compare(hex(Color.muted), "#8a8175")
            // mode dark wins over a light background.
            compare(ui.light, false)
            compare(hex(swatch.color), "#aa3300")
            var first = grabImage(swatch)
            compare(hex(first.pixel(8, 8)), "#aa3300")

            var seen = Color.revision
            writeColors("background = \"#16181c\"\nforeground = \"#e6e4df\"\naccent = \"#00bb77\"\nred = \"#dd3344\"\nmuted = \"#6e7680\"\n")
            tryVerify(function() { return Color.revision > seen && hex(Color.accent) === "#00bb77" }, 5000)
            compare(Color.mode, "")
            compare(ui.light, false)
            compare(hex(swatch.color), "#00bb77")

            seen = Color.revision
            replaceTheme("mode = \"light\"\nbackground = \"#121418\"\nforeground = \"#f2f0ea\"\naccent = \"#2266ee\"\nred = \"#e23b3b\"\nmuted = \"#9aa0a8\"\n")
            tryVerify(function() { return Color.revision > seen && hex(Color.accent) === "#2266ee" }, 5000)
            compare(Color.mode, "light")
            compare(hex(Color.background), "#121418")
            // mode light wins over a dark background, without restarting.
            compare(ui.light, true)
            compare(hex(swatch.color), "#2266ee")
            var second = grabImage(swatch)
            compare(hex(second.pixel(8, 8)), "#2266ee")

            seen = Color.revision
            replaceTheme("mode = \"dark\"\nnot a palette\n")
            tryVerify(function() { return Color.revision > seen }, 5000)
            wait(400)
            compare(Color.omarchyTheme, true)
            compare(Color.mode, "light")
            compare(hex(Color.accent), "#2266ee")
            compare(hex(Color.background), "#121418")
            compare(hex(swatch.color), "#2266ee")

            seen = Color.revision
            runPy("import pathlib, os\npath = pathlib.Path(os.environ['HOME']) / '.local/state/omarchy/current/theme/colors.toml'\npath.unlink()\n")
            tryVerify(function() { return Color.revision > seen && Color.omarchyTheme === false }, 5000)
            wait(400)
            compare(Color.omarchyTheme, false)
        }
    }
}
