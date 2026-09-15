#!/usr/bin/env python3
"""Check the Claude handoffs and the settings helper against an isolated Omabib service."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse, parse_qs

binary = str(Path(sys.argv[1]).resolve())
scripts = Path(__file__).parent
with tempfile.TemporaryDirectory(prefix='omabib-claude-test-') as directory:
    root = Path(directory)
    os.environ['XDG_CONFIG_HOME'] = str(root / 'config')
    os.environ['XDG_DATA_HOME'] = str(root / 'data')
    os.environ['XDG_DATA_DIRS'] = str(root / 'system')
    os.environ['PATH'] = str(Path(binary).parent) + os.pathsep + os.environ['PATH']
    api = runpy.run_path(str(scripts / 'omabib-claude'))
    settings = runpy.run_path(str(scripts / 'omabib-settings'))
    sock = str(root / 'library socket')
    service = subprocess.Popen([binary, 'serve', '--db', str(root / 'library.db')], env=dict(os.environ, OMABIB_SOCKET=sock),
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if Path(sock).exists():
                break
            time.sleep(.05)
        call = lambda method, params: api['shared']['library_call'](sock, method, params)
        rid = call('import_bibtex', {'bibtex': '@article{claude_fixture,title={Claude context "fixture" & more},year={2026}}'})['items'][0]['id']
        project = call('create_project', {'name': 'Context project'})['id']
        call('add_note', dict(ref_id=rid, project_id=project, body='A project note', provenance='test'))

        # Terminal: Claude Code gets the context folder, an MCP config for this library and the shared prompt.
        folder, context = api['shared']['prepare'](sock, rid, project, root / 'chats')
        argv = api['claude_command'](folder, context)
        assert Path(argv[0]).name == 'claude', argv
        config = json.loads(Path(argv[argv.index('--mcp-config') + 1]).read_text())
        server = config['mcpServers']['omabib']
        assert server['args'] == ['mcp'] and server['env']['OMABIB_SOCKET'] == sock, config
        assert (folder / 'mcp.json').stat().st_mode & 0o077 == 0
        assert argv[argv.index('--add-dir') + 1] == str(folder)
        assert argv[argv.index('--name') + 1] == 'Omabib · claude_fixture'
        assert argv[-2] == '--' and str(folder / 'context.json') in argv[-1]
        print('PASS: Claude Code command carries the context, MCP config and session name', flush=True)

        # Desktop: a claude:// new-chat link whose prompt names the entry for the MCP tools.
        url = api['desktop_url'](context)
        parsed = urlparse(url)
        assert parsed.scheme == 'claude' and parsed.netloc == 'claude.ai' and parsed.path == '/new', url
        prompt = parse_qs(parsed.query)['q'][0]
        assert rid in prompt and project in prompt and 'claude_fixture' in prompt and 'get_reference' in prompt, prompt
        assert '&' not in url.split('?q=', 1)[1] and unquote(url.split('?q=', 1)[1]) == prompt
        print('PASS: Claude Desktop link prompts for the entry through Omabib tools', flush=True)

        # Settings: defaults, validation, and PDF viewers from desktop entries.
        assert settings['load']() == dict(pdf_viewer='', ai_cli='codex', ai_desktop='chatgpt')
        apps = root / 'data/applications'; apps.mkdir(parents=True)
        (apps / 'viewer.desktop').write_text('[Desktop Entry]\nType=Application\nName=Test Viewer\nExec=sh %f\nMimeType=text/plain;application/pdf;\n\n[Desktop Action Other]\nName=Ignored\n')
        (apps / 'notpdf.desktop').write_text('[Desktop Entry]\nType=Application\nName=Not a viewer\nExec=sh %f\nMimeType=text/plain;\n')
        (apps / 'missing.desktop').write_text('[Desktop Entry]\nType=Application\nName=Missing\nExec=no-such-program-omabib %f\nMimeType=application/pdf;\n')
        shown = json.loads(subprocess.check_output([sys.executable, str(scripts / 'omabib-settings')], text=True))
        assert [v['id'] for v in shown['pdf_viewers']] == ['viewer.desktop'], shown['pdf_viewers']
        assert shown['pdf_viewers'][0]['name'] == 'Test Viewer'
        for key, value in [('pdf_viewer', 'viewer.desktop'), ('ai_cli', 'claude'), ('ai_desktop', 'claude')]:
            out = json.loads(subprocess.check_output([sys.executable, str(scripts / 'omabib-settings'), 'set', key, value], text=True))
            assert out['settings'][key] == value, out
        for key, value in [('pdf_viewer', 'missing.desktop'), ('ai_cli', 'gemini'), ('colour', 'red')]:
            result = subprocess.run([sys.executable, str(scripts / 'omabib-settings'), 'set', key, value], capture_output=True, text=True)
            assert result.returncode == 1 and 'error' in json.loads(result.stdout), result.stdout
        assert json.loads((root / 'config/omabib/settings.json').read_text()) == dict(pdf_viewer='viewer.desktop', ai_cli='claude', ai_desktop='claude')
        print('PASS: settings validate choices and list installed PDF viewers', flush=True)

        # Claude Desktop registration keeps the user's config and backs it up once.
        desktop_config = root / 'config/Claude/claude_desktop_config.json'
        desktop_config.parent.mkdir(parents=True)
        original = {'preferences': {'theme': 'dark'}, 'mcpServers': {'other': {'command': 'other-mcp'}}}
        desktop_config.write_text(json.dumps(original))
        desktop_config.chmod(0o600)
        assert not settings['claude_desktop_registered']()
        out = json.loads(subprocess.check_output([sys.executable, str(scripts / 'omabib-settings'), 'register-claude-desktop', sock], text=True))
        assert out['claude_desktop_mcp'] is True
        merged = json.loads(desktop_config.read_text())
        assert merged['preferences'] == original['preferences'] and merged['mcpServers']['other'] == original['mcpServers']['other']
        assert merged['mcpServers']['omabib']['env']['OMABIB_SOCKET'] == sock
        assert desktop_config.stat().st_mode & 0o777 == 0o600
        assert json.loads((desktop_config.parent / 'claude_desktop_config.json.omabib-backup').read_text()) == original
        print('PASS: Claude Desktop registration merges into its config and keeps a backup', flush=True)
    finally:
        service.terminate(); service.wait(timeout=5)
