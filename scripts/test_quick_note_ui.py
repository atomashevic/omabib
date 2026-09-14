#!/usr/bin/env python3
"""Live quick-note save/cancel/mismatch regression test using an isolated library."""
import json
import base64
import runpy
import os
import pathlib
import signal
import socket
import subprocess
import tempfile
import time

BINARY = str(pathlib.Path.home() / '.local/bin/omabib')
HELPER = str(pathlib.Path(__file__).with_name('omabib-quick-note').resolve())
REAL_SOCKET = os.environ.get('OMABIB_SOCKET', os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000') + '/omabib/socket')


def command(*args):
    return subprocess.check_output(args, text=True, timeout=5).strip()


def open_editor():
    context = command(HELPER, '--print')
    command('omarchy-shell', 'shell', 'summon', 'omabib', context)


def state():
    return json.loads(command('omarchy-shell', 'omabib', 'state'))


def active():
    return json.loads(command('hyprctl', 'activewindow', '-j'))


def wait(predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(state())


def pdf(path):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>']
    objects += [b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>'] * 3
    data = bytearray(b'%PDF-1.4\n'); offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data)); data += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(data)
    data += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]:
        data += f'{offset:010d} 00000 n \n'.encode()
    data += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    path.write_bytes(data)


initial = state()
assert not initial['editor_open'], 'An editor is open; preserve its draft.'
original_window = active().get('address')
with tempfile.TemporaryDirectory(prefix='omabib-quick-note-ui-') as directory:
    root = pathlib.Path(directory)
    sock = root / 'socket'
    service = subprocess.Popen([BINARY, 'serve', '--db', str(root / 'library.db')],
                               env=dict(os.environ, OMABIB_SOCKET=str(sock)),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    viewer_pid = None
    capture_installed = pathlib.Path.home() / '.local/bin/omabib-capture-note'
    capture_original = None
    visual = os.environ.get('OMABIB_TEST_VISUAL') == '1'

    try:
        wait(lambda: sock.exists())
        def call(method, params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(3); connection.connect(str(sock))
                connection.sendall((json.dumps(dict(v=1, id=1, method=method, params=params)) + '\n').encode())
                response = json.loads(connection.makefile().readline())
                assert 'error' not in response, response
                return response['result']
        imported = call('import_bibtex', dict(bibtex='@article{quick_note_fixture,title={Quick note verification},year={2026}}\n@article{other_fixture,title={Other reference},year={2026}}'))
        rid = next(r['id'] for r in imported['items'] if r['citekey'] == 'quick_note_fixture')
        project = call('create_project', dict(name='Quick note verification'))['id']
        path = root / 'paper.pdf'; pdf(path)
        call('attach', dict(ref_id=rid, path=str(path), file_type='pdf'))
        for item in imported['items']:
            call('associate', dict(ref_id=item['id'], project_id=project, labels=[]))
        command('omarchy-shell', 'shell', 'summon', 'omabib', json.dumps(dict(socket_path=str(sock), query='quick_note_fixture', project_id=project)))
        wait(lambda: state()['query_focused'] and state()['results'] == ['quick_note_fixture'])
        command('wtype', '-k', 'Tab')
        wait(lambda: state()['selected'] == rid)
        command('wtype', '-k', 'Return')
        viewer = wait(lambda: next((a for a in json.loads(command('hyprctl','clients','-j')) if a.get('class') == 'org.pwmt.zathura' and str(path) in a.get('title','')), None))
        viewer_pid = viewer['pid']
        destination = f'org.pwmt.zathura.PID-{viewer_pid}'
        command('gdbus', 'call', '--session', '--dest', destination, '--object-path', '/org/pwmt/zathura', '--method', 'org.pwmt.zathura.GotoPage', '2')
        command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{viewer["address"]}" }})')
        wait(lambda: active().get('pid') == viewer_pid)
        context = json.loads(command(HELPER, '--print'))
        assert context['ref_id'] == rid and context['page'] == 3 and context['total_pages'] == 3, context
        started = time.monotonic()
        if os.environ.get('OMABIB_TEST_HOTKEY') == '1':
            command('wtype', '-M', 'logo', '-k', 'n', '-m', 'logo')
        else:
            open_editor()
        wait(lambda: state()['quick_note'] and state()['editor_open'] and state()['editor_focused'])
        print(f'PASS: quick-note command opened editor in {(time.monotonic()-started)*1000:.0f} ms', flush=True)
        s = state()
        assert s['note_target_id'] == rid and s['note_scope'] == 1 and 'PDF p. 3' in s['note_evidence'], s
        screenshot = os.environ.get('OMABIB_TEST_SCREENSHOT')
        if screenshot and not visual:
            command('grim', screenshot)
        # Background search changes must not retarget an already-open editor.
        command('omarchy-shell', 'omabib', 'setQuery', 'other_fixture')
        other_id = next(r['id'] for r in imported['items'] if r['citekey'] == 'other_fixture')
        wait(lambda: state()['selected'] == other_id)
        if visual:
            # Mock only the mouse selection boundary; capture real pixels via grim.
            geometry = f"{viewer['at'][0]+20},{viewer['at'][1]+20} 160x100"
            capture_source = str(pathlib.Path(__file__).with_name('omabib-capture-note').resolve())
            capture_original = capture_installed.read_bytes()
            capture_installed.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execv(' + repr(capture_source) + ',[' + repr(capture_source) + ',"--geometry",' + repr(geometry) + ']+sys.argv[1:])\n')
            command('wtype', '-M', 'ctrl', '-M', 'shift', '-k', 'c', '-m', 'shift', '-m', 'ctrl')
            wait(lambda: bool(state().get('clip_path')) and not state()['capture_busy'])
            draft = pathlib.Path(state()['clip_path']); pixels = draft.read_bytes()
            assert pixels.startswith(b'\x89PNG\r\n\x1a\n')
            if screenshot:
                time.sleep(.4)
                monitor = next(m for m in json.loads(command('hyprctl','monitors','-j')) if m['id']==viewer['monitor'])
                sw, sh = monitor['width']/monitor['scale'], monitor['height']/monitor['scale']
                rect = f"{int(monitor['x']+(sw-440)/2)},{int(monitor['y']+(sh-410)/2)} 440x410"
                command('grim','-g',rect,screenshot)

        else:
            command('wtype', 'Page three verification note')
        command('wtype', '-M', 'ctrl', '-k', 'Return', '-m', 'ctrl')
        wait(lambda: not state()['opened'] and active().get('pid') == viewer_pid)
        notes = call('get_reference', dict(id=rid, include_notes=True, project_id=project))['notes']
        assert len(notes) == 1 and notes[0]['body'] == ('' if visual else 'Page three verification note'), notes
        assert notes[0]['project_id'] == project and 'PDF p. 3' in notes[0]['evidence'], notes
        print('PASS: PDF identity, page 3, project scope, fixed target, Ctrl+Enter save', flush=True)
        if visual:
            wait(lambda: not draft.exists())
            image = call('get_note_image', dict(note_id=notes[0]['id'], project_id=project))
            assert base64.b64decode(image['data']) == pixels
            request = dict(jsonrpc='2.0', id=1, method='tools/call', params=dict(name='get_note_image', arguments=dict(note_id=notes[0]['id'], project_id=project)))
            mcp = subprocess.run([BINARY,'mcp'], input=json.dumps(request)+'\n', text=True, capture_output=True, env=dict(os.environ,OMABIB_SOCKET=str(sock)), timeout=5)
            response = json.loads(mcp.stdout)['result']; assert not response['isError'], response
            block = next(b for b in response['content'] if b['type']=='image')
            assert block['mimeType']=='image/png' and base64.b64decode(block['data'])==pixels
            history = runpy.run_path(str(pathlib.Path(__file__).with_name('history_snapshot.py')))
            repository = root / 'history'; repository.mkdir()
            history['snapshot'].__globals__['REPO'] = repository
            history['snapshot'](root/'library.db')
            assert (repository/'notes'/'images'/(notes[0]['id']+'.png')).read_bytes()==pixels
            assert '![PDF page 3]' in (repository/'notes'/(notes[0]['id']+'.md')).read_text()
            print('PASS: image-only note, identical MCP image bytes, history PNG, draft cleanup', flush=True)

        command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{viewer["address"]}" }})')
        open_editor()
        wait(lambda: state()['editor_open'] and state()['editor_focused'])
        command('wtype', 'Unsaved draft')
        if visual:
            command('wtype', '-M', 'ctrl', '-M', 'shift', '-k', 'c', '-m', 'shift', '-m', 'ctrl')
            wait(lambda: bool(state().get('clip_path')) and not state()['capture_busy'])
            discarded = pathlib.Path(state()['clip_path'])
        command('wtype', '-k', 'Escape')
        wait(lambda: not state()['opened'] and active().get('pid') == viewer_pid)
        assert call('status', {})['notes'] == 1
        if visual: wait(lambda: not discarded.exists())
        print('PASS: Escape cancels without saving', flush=True)
        if visual:
            capture_installed.write_bytes(capture_original); capture_original = None
            open_editor()
            wait(lambda: state()['editor_open'] and state()['editor_focused'])
            command('wtype','-M','ctrl','-M','shift','-k','c','-m','shift','-m','ctrl')
            wait(lambda: state()['capture_busy'])
            # Wait for the actual picker surface before sending Escape.
            wait(lambda: '"namespace": "selection"' in command('hyprctl','layers','-j'))
            time.sleep(.3)
            command('wtype','-k','Escape')
            wait(lambda: not state()['capture_busy'] and state()['editor_open'])
            assert not state()['clip_path']
            command('wtype','-k','Escape')
            wait(lambda: not state()['opened'])
            assert call('status', {})['notes']==1
            print('PASS: real rectangle picker cancels and restores editor', flush=True)
            # Lose shell reading context, recover from exact attachment path.
            command('omarchy-shell','shell','summon','omabib',json.dumps(dict(socket_path=REAL_SOCKET)))
            wait(lambda: not state()['search_pending'])
            command('omarchy-shell','shell','hide','omabib')
            command('hyprctl','dispatch',f'hl.dsp.focus({{ window = "address:{viewer["address"]}" }})')
            recovered = json.loads(subprocess.check_output([HELPER,'--print'],text=True,env=dict(os.environ,OMABIB_SOCKET=str(sock))))
            assert recovered['ref_id']==rid and not recovered['project_id']
            capture_original=capture_installed.read_bytes()
            point=f"{viewer['at'][0]+20},{viewer['at'][1]+20} 0x0"
            capture_installed.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execv('+repr(capture_source)+',['+repr(capture_source)+',"--geometry",'+repr(point)+']+sys.argv[1:])\n')
            subprocess.check_call([str(pathlib.Path.home()/'.local/bin/omabib-quick-note')],env=dict(os.environ,OMABIB_SOCKET=str(sock)),timeout=5)
            wait(lambda: state()['editor_open'] and state()['editor_focused'])
            assert state()['note_target_id']==rid and not state()['clip_path']
            command('wtype','-k','Escape')
            wait(lambda: not state()['opened'])
            capture_installed.write_text('#!/usr/bin/env python3\nimport os,sys\nos.execv('+repr(capture_source)+',['+repr(capture_source)+',"--geometry",'+repr(geometry)+']+sys.argv[1:])\n')
            subprocess.check_call([str(pathlib.Path.home()/'.local/bin/omabib-quick-note')],env=dict(os.environ,OMABIB_SOCKET=str(sock)),timeout=5)
            wait(lambda: state()['editor_open'] and state()['editor_focused'])
            assert state()['clip_path'] and state()['note_target_id']==rid
            image_draft=pathlib.Path(state()['clip_path'])
            command('wtype','-k','Escape')
            wait(lambda: not state()['opened'] and not image_draft.exists())
            capture_installed.write_bytes(capture_original);capture_original=None
            print('PASS: filename recovery and rectangle-first point opens text-only editor',flush=True)

        other = root / 'other' / 'paper.pdf'; other.parent.mkdir(); pdf(other)
        command('gdbus', 'call', '--session', '--dest', destination, '--object-path', '/org/pwmt/zathura', '--method', 'org.pwmt.zathura.OpenDocument', str(other), '', '0')
        wait(lambda: str(other) in active().get('title', ''))
        rejected = subprocess.run([HELPER, '--print'], capture_output=True, text=True, timeout=5)
        assert rejected.returncode != 0 and 'Cannot link this PDF' in rejected.stderr, rejected
        assert not state()['editor_open'] and call('status', {})['notes'] == 1
        print('PASS: different PDF with identical basename rejected', flush=True)
    finally:
        if capture_original is not None: capture_installed.write_bytes(capture_original)
        command('omarchy-shell', 'shell', 'hide', 'omabib')
        command('omarchy-shell', 'shell', 'summon', 'omabib', json.dumps(dict(socket_path=REAL_SOCKET, query=initial['query'], project_id='')))
        wait(lambda: not state()['search_pending'] and not state()['error'] and 'quick_note_fixture' not in state()['results'])
        command('omarchy-shell', 'shell', 'hide', 'omabib')
        if viewer_pid:
            try: os.kill(viewer_pid, signal.SIGTERM)
            except ProcessLookupError: pass
        service.terminate(); service.wait(timeout=5)
        if original_window:
            command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{original_window}" }})')
