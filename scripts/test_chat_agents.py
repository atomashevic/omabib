#!/usr/bin/env python3
"""Chat with the real Claude Code and Codex through an isolated Omabib service.

No desktop involved. For each installed agent: ask for the paper's title (a read),
then ask it to save a note, which must wait in Omabib's approval queue. Claude's
write is allowed and the note must exist; Codex's is denied and no note may be
written. Uses a few messages of each subscription.

  scripts/test_chat_agents.py target/release/omabib [claude|codex|all]
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
fixtures = runpy.run_path(str(ROOT / 'scripts/record_chat_fixtures.py'))


class Events:
    """A subscribed connection collecting pushed chat events."""

    def __init__(self, sock):
        self.events, self.lock = [], threading.Lock()
        self.conn = socket.socket(socket.AF_UNIX)
        self.conn.connect(sock)
        self.conn.sendall(b'{"v":1,"id":1,"method":"chat_subscribe","params":{}}\n')
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.conn.makefile():
            message = json.loads(line)
            if message.get('event') == 'chat':
                with self.lock:
                    self.events.append(message)

    def wait(self, predicate, what, seconds=240):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            with self.lock:
                found = [e for e in self.events if predicate(e)]
            if found:
                return found
            time.sleep(0.2)
        with self.lock:
            tail = [(e['kind'], e['data']) for e in self.events[-12:]]
        raise AssertionError(f'timed out waiting for {what}: {tail}')


def call(sock, method, params, timeout=60):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(timeout)
        conn.connect(sock)
        conn.sendall((json.dumps(dict(v=1, id=1, method=method, params=params)) + '\n').encode())
        reply = json.loads(conn.makefile().readline())
    if 'error' in reply:
        raise RuntimeError(reply['error']['message'])
    return reply['result']


def run_agent(agent, sock, rid, events, allow):
    chat = call(sock, 'chat_start', {'ref_id': rid, 'agent': agent})['chat']['id']
    turns = lambda e: e['chat_id'] == chat and e['kind'] == 'turn_end'
    call(sock, 'chat_send', {'chat_id': chat, 'text': 'What is the title of this paper? Answer in one line.'})
    events.wait(lambda e: turns(e), f'{agent} first turn')
    answers = [e['data']['text'] for e in events.events if e['chat_id'] == chat and e['kind'] == 'assistant']
    assert any('sparse attention is enough' in a.lower() for a in answers), answers
    errors = [e['data'] for e in events.events if e['chat_id'] == chat and e['kind'] == 'error']
    assert not errors, errors
    print(f'PASS: {agent} answered from the paper', flush=True)

    call(sock, 'chat_send', {'chat_id': chat, 'text': 'Save a global note on this reference with the omabib add_note tool. Body: chat fixture note.'})
    request = events.wait(lambda e: e['chat_id'] == chat and e['kind'] == 'approval', f'{agent} approval request')[0]['data']
    assert request['tool'] == 'mcp__omabib__add_note', request
    notes_before = len(call(sock, 'get_reference', {'id': rid, 'include_notes': True})['notes'])
    call(sock, 'chat_approve', {'chat_id': chat, 'request_id': request['request_id'], 'allow': allow})
    events.wait(lambda e: turns(e) and e['seq'] > request_seq(events, chat), f'{agent} turn after the decision')
    notes = call(sock, 'get_reference', {'id': rid, 'include_notes': True})['notes']
    saved = [n for n in notes if 'chat fixture note' in n['body']]
    if allow:
        assert len(notes) == notes_before + 1 and saved, notes
        print(f'PASS: {agent} waited for approval and saved the note once allowed', flush=True)
    else:
        assert len(notes) == notes_before and not saved, notes
        print(f'PASS: {agent} waited for approval and wrote nothing when denied', flush=True)
    history = call(sock, 'chat_get', {'chat_id': chat})
    kinds = [e['kind'] for e in history['events']]
    assert kinds.count('user') == 2 and 'approval_result' in kinds, kinds
    return chat


def request_seq(events, chat):
    return max(e['seq'] for e in events.events if e['chat_id'] == chat and e['kind'] == 'approval')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    which = sys.argv[2] if len(sys.argv) > 2 else 'all'
    with tempfile.TemporaryDirectory(prefix='omabib-chat-live-') as d:
        tmp = Path(d)
        env_sock = str(tmp / 'socket')
        os.environ['OMABIB_SOCKET'] = env_sock
        service, sock, rid, _, _ = fixtures['start_library'](tmp, binary)
        try:
            events = Events(str(sock))
            if which in ('claude', 'all') and shutil.which('claude'):
                run_agent('claude', str(sock), rid, events, allow=True)
            if which in ('codex', 'all') and shutil.which('codex'):
                run_agent('codex', str(sock), rid, events, allow=False)
        finally:
            service.terminate()
            service.wait(timeout=5)


if __name__ == '__main__':
    main()
