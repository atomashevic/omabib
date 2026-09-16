#!/usr/bin/env python3
"""Record Claude Code and Codex event streams for the chat adapters' tests.

Runs short scripted chats against an isolated Omabib library (a two-page
fixture PDF with one note) and saves each CLI's stdout, scrubbed of home paths
and personal configuration, under tests/fixtures/chat/. Re-run after a CLI
update and check the adapter tests. Uses a few messages of each subscription.

  scripts/record_chat_fixtures.py target/release/omabib [claude|codex|all]
"""
import base64
import json
import os
from pathlib import Path
import re
import runpy
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import zlib
import struct

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'tests/fixtures/chat'
HOME = str(Path.home())


def fixture_pdf(path):
    content = (b"BT /F1 24 Tf 72 700 Td (Sparse attention is enough) Tj ET\n"
               b"BT /F1 12 Tf 72 650 Td (Table 2 reports the headline result: 2 percent.) Tj ET\n"
               b"0 0 1 rg 72 400 200 100 re f\n")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    data, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, obj in enumerate(objects):
        offsets.append(len(data))
        data += b"%d 0 obj\n" % (i + 1) + obj + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for off in offsets:
        data += b"%010d 00000 n \n" % off
    data += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    path.write_bytes(bytes(data))


def blue_png(path):
    w = h = 32
    raw = b''.join(b'\x00' + bytes([20, 60, 220]) * w for _ in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


PERMISSION_SERVER = r'''
import json, sys
log = open(sys.argv[1], "a")
for line in sys.stdin:
    req = json.loads(line)
    method, rid = req.get("method"), req.get("id")
    if method == "initialize":
        res = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "perm", "version": "0"}}
    elif method == "tools/list":
        res = {"tools": [{"name": "chat_permission", "description": "Approve a tool call", "inputSchema": {"type": "object", "properties": {"tool_name": {"type": "string"}, "input": {"type": "object"}, "tool_use_id": {"type": "string"}}, "required": ["tool_name", "input"]}}]}
    elif method == "tools/call":
        args = req["params"].get("arguments", {})
        log.write(json.dumps(args) + "\n"); log.flush()
        allow = args.get("tool_name") == "Bash"
        decision = {"behavior": "allow", "updatedInput": args.get("input", {})} if allow else {"behavior": "deny", "message": "Denied by fixture"}
        res = {"content": [{"type": "text", "text": json.dumps(decision)}]}
    elif rid is None:
        continue
    else:
        res = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": res}) + "\n"); sys.stdout.flush()
'''


def scrub(line, tmp):
    line = line.replace(str(tmp), '/tmp/omabib-chat-fixture').replace(HOME, '/home/reader')
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return line
    if event.get('type') == 'system' and event.get('subtype') == 'init':
        for key in ('slash_commands', 'agents', 'skills', 'plugins', 'output_style', 'memory_paths'):
            if key in event:
                event[key] = []
        event['tools'] = [t for t in event.get('tools', []) if not str(t).startswith('mcp__') or 'omabib' in t or 'perm' in t]
        if 'messaging_socket_path' in event:
            event['messaging_socket_path'] = '/run/user/1000/cc-socks/fixture.sock'
    if event.get('type') == 'rate_limit_event':
        # Plan usage and overage state are account details, not test data.
        event['rate_limit_info'] = {'status': 'allowed', 'rateLimitType': 'five_hour', 'unifiedWindows': {'five_hour': {'utilization': 0.5}}}
    text = json.dumps(event, ensure_ascii=False)
    return re.sub(r'[\w.+-]+@[\w-]+\.[\w.]+', 'reader@example.org', text)


def start_library(tmp, binary):
    sock = tmp / 'socket'
    service = subprocess.Popen([binary, 'serve', '--db', str(tmp / 'library.db')], env=dict(os.environ, OMABIB_SOCKET=str(sock)),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if sock.exists():
            break
        time.sleep(.05)
    call = runpy.run_path(str(ROOT / 'scripts/omabib-codex'))['library_call']
    rid = call(str(sock), 'import_bibtex', {'bibtex': '@article{sparse_fixture_2026,title={Sparse attention is enough},author={Okafor, Chidi},year={2026}}'})['items'][0]['id']
    pdf = tmp / 'paper.pdf'
    fixture_pdf(pdf)
    call(str(sock), 'attach', dict(ref_id=rid, path=str(pdf), file_type='pdf'))
    call(str(sock), 'add_note', dict(ref_id=rid, project_id=None, body='Table 2 is the headline result.', provenance='human', evidence='PDF p. 1'))
    folder, context = runpy.run_path(str(ROOT / 'scripts/omabib-codex'))['prepare'](str(sock), rid, '', tmp / 'chats')
    return service, sock, rid, folder, context


def record_claude(tmp, binary, sock, folder):
    perm_log = tmp / 'permission-requests.jsonl'
    perm = tmp / 'perm_server.py'
    perm.write_text(PERMISSION_SERVER)
    config = folder / 'mcp.json'
    config.write_text(json.dumps({'mcpServers': {
        'omabib': {'type': 'stdio', 'command': binary, 'args': ['mcp'], 'env': {'OMABIB_SOCKET': str(sock)}},
        'perm': {'type': 'stdio', 'command': sys.executable, 'args': [str(perm), str(perm_log)]}}}))
    png = tmp / 'blue.png'
    blue_png(png)
    argv = ['claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--include-partial-messages',
            '--verbose', '--session-id', str(uuid.uuid4()), '--mcp-config', str(config), '--strict-mcp-config',
            '--add-dir', str(folder), '--allowedTools', 'Read', 'Grep', 'Glob', 'mcp__omabib',
            '--permission-prompt-tool', 'mcp__perm__chat_permission',
            '--append-system-prompt', 'You are helping read one Omabib bibliography entry. Context: ' + str(folder / 'context.json')]
    proc = subprocess.Popen(argv, cwd=folder.parent, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    out_lines, in_lines = [], []

    def send(obj):
        line = json.dumps(obj)
        in_lines.append(line)
        proc.stdin.write(line + '\n')
        proc.stdin.flush()

    def user(content):
        send({'type': 'user', 'message': {'role': 'user', 'content': content}})

    def until(predicate, seconds=240):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError('claude exited: ' + proc.stderr.read()[-2000:])
            out_lines.append(line.rstrip('\n'))
            event = json.loads(line)
            if predicate(event):
                return event
        raise TimeoutError('claude turn timed out')

    is_result = lambda e: e.get('type') == 'result'
    user('What is the title of this paper? Verify it with the get_reference tool.')
    until(is_result)
    user('Use the Bash tool to run exactly: ls ' + str(folder))
    until(is_result)
    user([{'type': 'text', 'text': 'What color is this square? One word.'},
          {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': base64.b64encode(png.read_bytes()).decode()}}])
    until(is_result)
    user('Use the WebFetch tool to fetch https://example.org and tell me its title.')
    until(is_result)
    user('Write a 400 word explanation of self-attention.')
    until(lambda e: e.get('type') == 'stream_event' and e.get('event', {}).get('type') == 'content_block_delta')
    send({'type': 'control_request', 'request_id': 'interrupt-1', 'request': {'subtype': 'interrupt'}})
    until(is_result)
    user('Reply with just OK.')
    until(is_result)
    proc.stdin.close()
    proc.wait(timeout=60)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'claude-session.jsonl').write_text('\n'.join(scrub(l, tmp) for l in out_lines) + '\n')
    (OUT / 'claude-session.stdin.jsonl').write_text('\n'.join(scrub(l, tmp) for l in in_lines) + '\n')
    if perm_log.exists():
        (OUT / 'claude-permission-requests.jsonl').write_text('\n'.join(scrub(l, tmp) for l in perm_log.read_text().splitlines()) + '\n')
    print('claude:', len(out_lines), 'events', flush=True)


def record_codex(tmp, binary, sock, folder):
    server = 'mcp_servers.omabib={command=' + json.dumps(binary) + ',args=["mcp"],enabled=true,env={OMABIB_SOCKET=' + json.dumps(str(sock)) + '}}'
    png = tmp / 'blue.png'
    blue_png(png)
    OUT.mkdir(parents=True, exist_ok=True)
    thread = None

    def turn(name, prompt, image=None, interrupt=False):
        nonlocal thread
        base = ['codex', 'exec']
        if thread:
            base += ['resume', thread]
        argv = base + ['--json', '--skip-git-repo-check', '-c', server, '-c', 'sandbox_mode="read-only"']
        if image:
            argv += ['-i', str(image)]
        argv += ['--', prompt]
        proc = subprocess.Popen(argv, cwd=folder.parent, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        lines, deadline = [], time.monotonic() + 300
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            lines.append(line.rstrip('\n'))
            if interrupt and len(lines) >= 3:
                os.killpg(proc.pid, signal.SIGINT)
                interrupt = False
            if time.monotonic() > deadline:
                os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=60)
        for line in lines:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            for key in ('thread_id', 'session_id'):
                if not thread and isinstance(event.get(key), str):
                    thread = event[key]
        (OUT / f'codex-{name}.jsonl').write_text('\n'.join(scrub(l, tmp) for l in lines) + '\n')
        print(f'codex {name}:', len(lines), 'events, exit', proc.returncode, flush=True)

    turn('1-title', 'Read ' + str(folder / 'context.json') + '. What is the title of this paper? Verify it with the omabib get_reference tool.')
    turn('2-shell', 'Run the shell command: ls ' + str(folder))
    turn('3-image', 'What color is the attached square? One word.', image=png)
    turn('4-write', 'Save a note on this reference with the omabib add_note tool. Body: fixture note.')
    turn('5-interrupt', 'Write a 400 word explanation of self-attention.', interrupt=True)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    which = sys.argv[2] if len(sys.argv) > 2 else 'all'
    with tempfile.TemporaryDirectory(prefix='omabib-chat-fixture-') as d:
        tmp = Path(d)
        service, sock, rid, folder, context = start_library(tmp, binary)
        try:
            if which in ('claude', 'all'):
                record_claude(tmp, binary, sock, folder)
            if which in ('codex', 'all'):
                record_codex(tmp, binary, sock, folder)
        finally:
            service.terminate()
            service.wait(timeout=5)


if __name__ == '__main__':
    main()
