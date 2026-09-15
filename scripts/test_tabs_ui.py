#!/usr/bin/env python3
"""Exercise the detail tabs, the AI summary, menus and the command palette on an isolated library.

The alphaXiv overview is written to the fixture database's cache first, so the
AI summary tab loads without network access. Requires wtype and Omarchy.
"""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time

BIN = str(Path.home() / '.local/bin/omabib')
REAL_SOCKET = os.environ.get('OMABIB_SOCKET', os.environ.get('XDG_RUNTIME_DIR', '/run/user/1000') + '/omabib/socket')
CAPTURE = os.environ.get('OMABIB_TABS_CAPTURE_DIR')

OVERVIEW = """# Research Report: "Tab fixture"

## 1. Authors and Institutions

Written by **A. Fixture** at an example lab.

## 2. Main Findings and Results

1. Tabs switch with Ctrl+1 to Ctrl+5.
2. The overview is read from the local cache.
"""


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


def keys(*args):
    command('wtype', *args)


def ctrl(key):
    keys('-M', 'ctrl', '-k', key, '-m', 'ctrl')


def capture(name):
    if not CAPTURE:
        return
    time.sleep(.3)
    layers = json.loads(command('hyprctl', 'layers', '-j'))
    matches = [layer for monitor in layers.values() for group in monitor['levels'].values()
               for layer in group if 'omabib' in layer['namespace']]
    assert len(matches) == 1, matches
    layer = matches[0]
    output = Path(CAPTURE) / f'{name}.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['grim', '-g', f"{layer['x']},{layer['y']} {layer['w']}x{layer['h']}", str(output)], check=True)


initial = state()
assert not initial['editor_open'] and not initial['opened'], 'Preserve the open Omabib window or draft.'
original_window = json.loads(command('hyprctl', 'activewindow', '-j')).get('address')

with tempfile.TemporaryDirectory(prefix='omabib-tabs-ui-') as dirname:
    root = Path(dirname)
    db = root / 'library.db'
    sock = root / 'socket'
    service = subprocess.Popen([BIN, 'serve', '--db', str(db)], env=dict(os.environ, OMABIB_SOCKET=str(sock)),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait(sock.exists)

        def call(method, params):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(sock))
                connection.sendall((json.dumps(dict(v=1, id=1, method=method, params=params)) + '\n').encode())
                reply = json.loads(connection.makefile().readline())
            assert 'error' not in reply, reply
            return reply['result']

        items = call('import_bibtex', dict(bibtex='''@misc{tabs_arxiv_fixture,title={Tabs arXiv fixture},author={Fixture, Ada},year={2026},doi={10.48550/arxiv.2609.99999},abstract={An abstract for the overview tab.}}
@article{tabs_plain_fixture,title={Tabs plain fixture},year={2025}}'''))['items']
        ids = {item['citekey']: item['id'] for item in items}
        with sqlite3.connect(db) as connection:
            connection.execute("INSERT INTO external_summaries(ref_id,source,external_id,source_url,body) VALUES(?,?,?,?,?)",
                               (ids['tabs_arxiv_fixture'], 'alphaXiv', '2609.99999', 'https://www.alphaxiv.org/overview/2609.99999', OVERVIEW))
        cached = call('get_alphaxiv_overview', dict(id=ids['tabs_arxiv_fixture']))
        assert cached['cached'] and cached['body'] == OVERVIEW, cached
        call('create_project', dict(name='Tabs UI'))

        command('omarchy-shell', 'shell', 'summon', 'omabib', json.dumps(dict(socket_path=str(sock), query='', project_id='', ref_id=ids['tabs_arxiv_fixture'])))
        wait(lambda: state()['expanded'] and state()['selected'] == ids['tabs_arxiv_fixture'])
        capture('1-overview')

        for key, tab in [('3', 'notes'), ('4', 'files'), ('5', 'bibtex'), ('1', 'overview')]:
            ctrl(key)
            wait(lambda: state()['detail_tab'] == tab)
        print('PASS: Ctrl+1, 3, 4 and 5 switch the detail tabs', flush=True)

        ctrl('2')
        wait(lambda: state()['overview_visible'] and not state()['overview_busy'])
        s = state()
        assert s['detail_tab'] == 'ai' and s['overview_state'] == 'ready' and s['overview_chars'] == len(OVERVIEW), s
        capture('2-ai-summary')
        print('PASS: Ctrl+2 opens the AI summary from the cached overview', flush=True)

        ctrl('Tab')
        wait(lambda: state()['detail_tab'] == 'notes')
        print('PASS: Ctrl+Tab cycles to the next tab', flush=True)

        ctrl('p')
        wait(lambda: state()['project_menu_open'])
        capture('3-project-menu')
        keys('-k', 'Escape')
        wait(lambda: not state()['project_menu_open'] and state()['opened'])
        print('PASS: Ctrl+P opens the project menu and Escape closes only the menu', flush=True)

        ctrl('k')
        wait(lambda: state()['commands_open'])
        keys('sync')
        capture('4-palette-filtered')
        keys('-k', 'Escape')
        wait(lambda: not state()['commands_open'] and state()['opened'])
        ctrl('k')
        wait(lambda: state()['commands_open'])
        keys('16')
        wait(lambda: state()['editor_open'] and state()['edit_kind'] == 'project')
        keys('-k', 'Escape')
        wait(lambda: not state()['editor_open'] and state()['opened'])
        print('PASS: the palette filters, closes on Escape and still runs numbered actions', flush=True)

        command('omarchy-shell', 'omabib', 'setQuery', 'Tabs plain fixture')
        wait(lambda: state()['results'] == ['tabs_plain_fixture'])
        keys('-k', 'Tab')
        wait(lambda: state()['selected'] == ids['tabs_plain_fixture'] and state()['detail_tab'] == 'notes')
        ctrl('2')
        wait(lambda: state()['notice'] != '')
        assert state()['detail_tab'] == 'notes', state()
        print('PASS: the AI summary stays unavailable for a paper without an arXiv ID', flush=True)

        # Paper tabs: open, switch, survive closing the popup, close manually.
        tabs_file = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'omabib/tabs.json'
        ctrl('t')
        wait(lambda: state()['tabs'] == ['tabs_plain_fixture'] and state()['active_tab'] == 0)
        keys('-M', 'alt', '-k', '0', '-m', 'alt')
        wait(lambda: state()['active_tab'] == -1 and state()['query_focused'])
        command('omarchy-shell', 'omabib', 'setQuery', 'Tabs arXiv fixture')
        wait(lambda: state()['results'] == ['tabs_arxiv_fixture'])
        keys('-M', 'ctrl', '-k', 'Return', '-m', 'ctrl')
        wait(lambda: state()['tabs'] == ['tabs_plain_fixture', 'tabs_arxiv_fixture'] and state()['active_tab'] == 1)
        wait(lambda: state()['selected'] == ids['tabs_arxiv_fixture'])
        capture('5-paper-tab')
        ctrl('Prior')
        wait(lambda: state()['active_tab'] == 0 and state()['selected'] == ids['tabs_plain_fixture'])
        print('PASS: Ctrl+T and Ctrl+Enter open paper tabs; Alt+0 and Ctrl+PgUp switch tabs', flush=True)

        command('omarchy-shell', 'shell', 'hide', 'omabib')
        wait(lambda: not state()['opened'])
        saved = json.loads(tabs_file.read_text())['libraries'][str(sock)]
        assert [t['citekey'] for t in saved['tabs']] == ['tabs_plain_fixture', 'tabs_arxiv_fixture'] and saved['active'] == 0, saved
        command('omarchy-shell', 'shell', 'summon', 'omabib', '{}')
        wait(lambda: state()['opened'] and state()['active_tab'] == 0 and state()['selected'] == ids['tabs_plain_fixture'])
        print('PASS: tabs and the active tab survive closing the popup', flush=True)

        ctrl('w')
        wait(lambda: state()['tabs'] == ['tabs_arxiv_fixture'] and state()['active_tab'] == 0)
        command('omarchy-shell', 'omabib', 'closeTab', '0')
        wait(lambda: state()['tabs'] == [] and state()['active_tab'] == -1)
        assert str(sock) not in json.loads(tabs_file.read_text())['libraries']
        print('PASS: Ctrl+W and closeTab close tabs and forget the library entry', flush=True)
    finally:
        try:
            command('omarchy-shell', 'shell', 'hide', 'omabib')
            command('omarchy-shell', 'shell', 'summon', 'omabib', json.dumps(dict(socket_path=REAL_SOCKET, query=initial['query'], project_id=initial['project_id'])))
            wait(lambda: not state()['search_pending'] and not state()['error'] and 'tabs_plain_fixture' not in state()['results'])
            command('omarchy-shell', 'shell', 'hide', 'omabib')
        finally:
            service.terminate(); service.wait(timeout=5)
            if original_window:
                command('hyprctl', 'dispatch', f'hl.dsp.focus({{ window = "address:{original_window}" }})')
