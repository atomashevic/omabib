#!/usr/bin/env python3
"""Exercise reference and note confirmation dialogs with an isolated library."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


BIN = str(Path.home() / '.local/bin/omabib')
REAL_SOCKET = os.environ.get('OMABIB_SOCKET', os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000') + '/omabib/socket')
RESTORE = os.environ.get('OMABIB_RESTORE_STATE')
CAPTURE = os.environ.get('OMABIB_DELETE_CAPTURE_DIR')


def command(*args):
    return subprocess.check_output(args, text=True, timeout=8).strip()


def state():
    return json.loads(command('omarchy-shell', 'omabib', 'state'))


def wait(predicate, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(state())


def capture(name):
    if not CAPTURE:
        return
    layers = json.loads(command('hyprctl', 'layers', '-j'))
    matches = [layer for monitor in layers.values() for group in monitor['levels'].values()
               for layer in group if 'omabib' in layer['namespace']]
    assert len(matches) == 1, matches
    layer = matches[0]
    output = Path(CAPTURE) / f'{name}.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['grim', '-g', f"{layer['x']},{layer['y']} {layer['w']}x{layer['h']}", str(output)], check=True)


initial = json.loads(Path(RESTORE).read_text()) if RESTORE else state()
assert not initial['editor_open'], 'Preserve the active editor draft.'
assert not state()['editor_open'], 'Preserve the active editor draft.'
assert not state()['opened'], 'Preserve the open Omabib window.'
original_window = json.loads(command('hyprctl', 'activewindow', '-j')).get('address')

with tempfile.TemporaryDirectory(prefix='omabib-delete-ui-') as dirname:
    root = Path(dirname)
    sock = root / 'socket'
    service = subprocess.Popen([BIN, 'serve', '--db', str(root / 'library.db')],
                               env=dict(os.environ, OMABIB_SOCKET=str(sock)),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait(sock.exists)

        def call(method, params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(3)
                connection.connect(str(sock))
                connection.sendall((json.dumps(dict(v=1, id=1, method=method, params=params)) + '\n').encode())
                reply = json.loads(connection.makefile().readline())
            assert 'error' not in reply, reply
            return reply['result']

        imported = call('import_bibtex', dict(bibtex='@article{delete_ui_fixture,title={Delete UI fixture},year={2026}}'))
        rid = imported['items'][0]['id']
        project = call('create_project', dict(name='Delete UI test'))['id']
        note = call('add_note', dict(ref_id=rid, project_id=project, body='Delete this fixture note', provenance='test'))
        keep = call('add_note', dict(ref_id=rid, project_id=project, body='Keep this fixture note', provenance='test'))
        pdf = root / 'fixture.pdf'; pdf.write_bytes(b'%PDF-1.4\n')
        call('attach', dict(ref_id=rid, path=str(pdf), file_type='pdf'))
        command('omarchy-shell', 'shell', 'summon', 'io.github.atomashevic.omabib', json.dumps(dict(socket_path=str(sock), query='delete_ui_fixture', project_id=project, ref_id=rid)))
        wait(lambda: state()['expanded'] and state()['selected'] == rid)

        command('omarchy-shell', 'omabib', 'openDelete')
        wait(lambda: state()['delete_open'] and state()['delete_preview'] == 'delete_ui_fixture')
        capture('delete-reference')
        command('wtype', '-k', 'Escape')
        wait(lambda: not state()['delete_open'])
        assert call('get_reference', dict(id=rid))['id'] == rid
        print('PASS: reference deletion preview and Escape cancellation', flush=True)

        command('omarchy-shell', 'omabib', 'openNoteDelete', note['id'])
        wait(lambda: state()['note_delete_open'] and state()['note_delete_preview'] == note['id'])
        capture('delete-note')
        command('wtype', '-k', 'Escape')
        wait(lambda: not state()['note_delete_open'])
        assert call('delete_note_preview', dict(id=note['id']))['id'] == note['id']
        command('omarchy-shell', 'omabib', 'openNoteDelete', note['id'])
        wait(lambda: state()['note_delete_open'])
        command('wtype', '-M', 'ctrl', '-k', 'Return', '-m', 'ctrl')
        wait(lambda: not state()['note_delete_open'])
        assert [n['id'] for n in call('get_reference', dict(id=rid, project_id=project, include_notes=True))['notes']] == [keep['id']]
        print('PASS: selected note deleted while reference and other note remain', flush=True)

        command('omarchy-shell', 'omabib', 'openDelete')
        wait(lambda: state()['delete_open'])
        command('wtype', '-M', 'ctrl', '-k', 'Return', '-m', 'ctrl')
        wait(lambda: not state()['delete_open'] and not state()['expanded'])
        assert not call('search', dict(query='Delete UI fixture'))['results']
        assert pdf.exists()
        print('PASS: reference deleted, search cleared, PDF file preserved', flush=True)
    finally:
        try:
            command('omarchy-shell', 'shell', 'hide', 'io.github.atomashevic.omabib')
            payload = dict(socket_path=REAL_SOCKET, query=initial['query'], project_id=initial['project_id'])
            if initial.get('expanded') and initial.get('selected'):
                payload['ref_id'] = initial['selected']
            command('omarchy-shell', 'shell', 'summon', 'io.github.atomashevic.omabib', json.dumps(payload))
            wait(lambda: not state()['search_pending'] and not state()['error'] and 'delete_ui_fixture' not in state()['results'])
            if initial.get('overview_visible') and initial.get('selected'):
                command('omarchy-shell', 'omabib', 'loadOverview')
                wait(lambda: state()['overview_visible'])
            if not initial['opened']:
                command('omarchy-shell', 'shell', 'hide', 'io.github.atomashevic.omabib')
        finally:
            service.terminate(); service.wait(timeout=5)
            if original_window:
                command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{original_window}" }})')
