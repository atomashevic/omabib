#!/usr/bin/env python3
"""Render and exercise the real first-run entry in an isolated offscreen Quickshell fixture."""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    output = ROOT / 'target/plugin-entry-shots'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='omabib-entry-test-') as temporary:
        fixture = Path(temporary)
        (fixture / 'plugin/components').mkdir(parents=True)
        (fixture / 'scripts').mkdir()
        (fixture / 'home').mkdir()
        (fixture / 'runtime').mkdir(mode=0o700)
        shutil.copytree(ROOT / 'tests/qml/imports/qs/Commons', fixture / 'Commons')
        shutil.copy2(ROOT / 'plugin/Entry.qml', fixture / 'plugin/Entry.qml')
        for name in ('Theme.qml', 'TextButton.qml', 'Icon.qml', 'Icons.js', 'Keycap.qml'):
            shutil.copy2(ROOT / 'plugin/components' / name, fixture / 'plugin/components' / name)
        (fixture / 'plugin/App.qml').write_text('''import QtQuick
Item {
 property var shell: null
 property var manifest: null
 property bool opened: false
 function open(payload) { opened = true }
 function close() { opened = false }
}
''')
        (fixture / 'scripts/omabib-plugin').write_text('''import sys, json, pathlib, os
flag = pathlib.Path(os.environ['HOME']) / 'attempted'
if sys.argv[1] == 'status': print(json.dumps({'ready':False}))
elif not flag.exists():
 flag.touch()
 print(json.dumps({'ready':False, 'error':'Download interrupted. Please try again.'}))
 sys.exit(1)
else: print(json.dumps({'ready':True}))
''')
        (fixture / 'shell.qml').write_text('''import QtQuick
import Quickshell
import "plugin"
ShellRoot {
 id: test
 property int phase: 0
 Entry { id: entry; Component.onCompleted: open("{}") }
 function fail(message) { console.error("TEST FAILED: " + message); Qt.quit() }
 function capture(name, next) {
  var window = null
  for(var i=0;i<entry.data.length;i++) if(entry.data[i].objectName === "omabibSetup") window=entry.data[i]
  if(!window || !window.visible) { fail("setup window is not visible"); return }
  phase = -1
  var surface = null
  for(var j=0;j<window.contentItem.children.length;j++) if(window.contentItem.children[j].objectName === "omabibSetupSurface") surface=window.contentItem.children[j]
  if(!surface) { fail("setup surface missing"); return }
  surface.grabToImage(function(result) {
   if(!result.saveToFile(Quickshell.env("TEST_SCREENSHOTS") + "/" + name + ".png")) { fail("screenshot failed"); return }
   phase=next
   entry.runSetup("install")
  })
 }
 Timer {
  interval: 200; running: true; repeat: true
  onTriggered: {
   if(entry.busy || test.phase===-1) return
   if(test.phase===0) {
    if(entry.ready || !entry.opened) { test.fail("initial setup state"); return }
    test.capture("welcome", 1)
   } else if(test.phase===1) {
    if(entry.ready || entry.setupError.indexOf("interrupted")===-1) { test.fail("failure state"); return }
    test.capture("retry", 2)
   } else if(test.phase===2 && entry.ready) {
    entry.close()
    if(entry.opened) { test.fail("close"); return }
    entry.open("{}")
    if(!entry.opened) { test.fail("reopen"); return }
    entry.toggle("{}")
    if(entry.opened) { test.fail("toggle"); return }
    console.log("PASS: setup, error, retry, backend loading, open, close, toggle")
    Qt.quit()
   }
  }
 }
 Timer { interval: 15000; running:true; onTriggered: test.fail("timeout") }
}
''')
        env = dict(os.environ, HOME=str(fixture / 'home'), XDG_RUNTIME_DIR=str(fixture / 'runtime'),
                   XDG_CONFIG_HOME=str(fixture / 'home/.config'), XDG_STATE_HOME=str(fixture / 'home/.local/state'),
                   XDG_CACHE_HOME=str(fixture / 'home/.cache'), TEST_SCREENSHOTS=str(output),
                   QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
                   PATH='/usr/bin:/bin')
        env.pop('WAYLAND_DISPLAY', None)
        result = subprocess.run(['quickshell', '--no-color', '-p', str(fixture / 'shell.qml')],
                                env=env, capture_output=True, text=True, timeout=25)
        print(result.stdout + result.stderr)
        assert result.returncode == 0 and 'PASS: setup' in result.stdout + result.stderr


if __name__ == '__main__':
    main()
