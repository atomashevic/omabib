#!/usr/bin/env python3
"""Exercise Super+B's command with a Zathura PDF and an isolated library."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


BIN = str(Path.home() / '.local/bin/omabib')
SOCKET = os.environ.get('OMABIB_SOCKET', os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000') + '/omabib/socket')


def command(*args, env=None):
    return subprocess.check_output(args, text=True, timeout=8, env=env).strip()


def state():
    return json.loads(command('omarchy-shell', 'omabib', 'state'))


def active():
    return json.loads(command('hyprctl', 'activewindow', '-j'))


def wait(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(state())


def pdf(path):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>']
    data = bytearray(b'%PDF-1.4\n'); offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data)); data += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(data)
    data += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]:
        data += f'{offset:010d} 00000 n \n'.encode()
    data += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    path.parent.mkdir()
    path.write_bytes(data)


initial = state()
assert not initial['opened'] and not initial['editor_open'], 'Preserve the active Omabib window or draft.'
original_window = active().get('address')
with tempfile.TemporaryDirectory(prefix='omabib-open-zathura-') as dirname:
    root = Path(dirname)
    sock = root / 'socket'
    service = subprocess.Popen([BIN, 'serve', '--db', str(root / 'library.db')],
                               env=dict(os.environ, OMABIB_SOCKET=str(sock)),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    viewer = None
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

        items = call('import_bibtex', dict(bibtex='@article{pdf_first,title={First PDF},year={2026}}\n@article{pdf_other,title={Other PDF},year={2026}}'))['items']
        ids = {item['citekey']: item['id'] for item in items}
        first = root / 'one' / 'paper.pdf'; pdf(first)
        other = root / 'two' / 'paper.pdf'; pdf(other)
        call('attach', dict(ref_id=ids['pdf_first'], path=str(first), file_type='pdf'))
        call('attach', dict(ref_id=ids['pdf_other'], path=str(other), file_type='pdf'))
        project = call('create_project', dict(name='Other project'))['id']
        call('associate', dict(ref_id=ids['pdf_other'], project_id=project, labels=[]))
        command('omarchy-shell', 'shell', 'summon', 'omabib', json.dumps(dict(socket_path=str(sock), query='pdf_other', project_id=project)))
        wait(lambda: state()['results'] == ['pdf_other'] and state()['project_id'] == project)
        command('omarchy-shell', 'shell', 'hide', 'omabib')

        viewer = subprocess.Popen(['zathura', str(first)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        window = wait(lambda: next((client for client in json.loads(command('hyprctl', 'clients', '-j'))
                                    if client.get('pid') == viewer.pid), None))
        command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{window["address"]}" }})')
        wait(lambda: active().get('pid') == viewer.pid)
        env = dict(os.environ, OMABIB_SOCKET=str(sock))
        command(BIN, 'open', env=env)
        wait(lambda: state()['opened'] and state()['expanded'] and state()['selected'] == ids['pdf_first'])
        s = state()
        assert s['query'] == 'pdf_first' and s['project_id'] == '' and s['results'] == ['pdf_first'], s
        print('PASS: Zathura PDF opens its exact Omabib item and resets the project filter', flush=True)

        command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{window["address"]}" }})')
        wait(lambda: active().get('pid') == viewer.pid)
        command(BIN, 'open', env=env)
        assert state()['opened'] and state()['selected'] == ids['pdf_first']
        print('PASS: repeated open summons the item instead of hiding Omabib', flush=True)

        command('omarchy-shell', 'shell', 'hide', 'omabib')
        if original_window:
            command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{original_window}" }})')
            wait(lambda: active().get('address') == original_window)
        command(BIN, 'open', env=env)
        wait(lambda: state()['opened'])
        command(BIN, 'open', env=env)
        wait(lambda: not state()['opened'])
        print('PASS: outside Zathura, Super+B command retains normal toggle behavior', flush=True)
    finally:
        command('omarchy-shell', 'shell', 'hide', 'omabib')
        command('omarchy-shell', 'shell', 'summon', 'omabib', json.dumps(dict(socket_path=SOCKET, query=initial['query'], project_id=initial['project_id'])))
        wait(lambda: not state()['search_pending'] and not state()['error'])
        command('omarchy-shell', 'shell', 'hide', 'omabib')
        if viewer is not None:
            viewer.terminate(); viewer.wait(timeout=5)
        service.terminate(); service.wait(timeout=5)
        if original_window:
            command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{original_window}" }})')
