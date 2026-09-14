#!/usr/bin/env python3
"""Check the Codex handoff against an isolated Omabib service."""
import base64
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
import tomllib
from urllib.parse import urlparse, parse_qs

api = runpy.run_path(str(Path(__file__).with_name('omabib-codex')))
binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='omabib-codex-test-') as directory:
    root = Path(directory)
    sock = str(root / 'library socket')
    service = subprocess.Popen([binary, 'serve', '--db', str(root / 'library.db')], env=dict(os.environ, OMABIB_SOCKET=sock), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if Path(sock).exists():
                break
            time.sleep(.05)
        def call(method, params):
            return api['library_call'](sock, method, params)
        rid = call('import_bibtex', {'bibtex':'@article{codex_fixture,title={Codex context fixture},year={2026}}'})['items'][0]['id']
        project = call('create_project', {'name':'Context project'})['id']
        for n in range(27):
            call('add_note', dict(ref_id=rid, project_id=project if n % 2 else None, body=f'Note {n}', provenance='test'))
        pdf = root / 'paper $(literal).pdf'
        pdf.write_bytes(b'%PDF-1.4\n')
        call('attach', dict(ref_id=rid, path=str(pdf), file_type='pdf'))
        png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
        image = root / 'clip.png'; image.write_bytes(png)
        call('add_visual_note', dict(ref_id=rid, project_id=project, body='Visual evidence', provenance='test', image_path=str(image), source_pdf=str(pdf), page=3, rectangle=dict(x=0,y=0,width=1,height=1)))
        folder, context = api['prepare'](sock, rid, project, root / 'chat folders')
        assert len(context['reference']['notes']) == 28
        assert context['active_project_id'] == project
        assert context['reference']['pdf_path'] == str(pdf)
        clips = [n for n in context['reference']['notes'] if n.get('image')]
        assert len(clips) == 1 and Path(clips[0]['image']['local_path']).read_bytes() == png
        assert folder.stat().st_mode & 0o077 == 0
        assert (folder / 'context.json').stat().st_mode & 0o077 == 0
        argv = api['codex_command'](folder, context)
        assert argv[argv.index('--model') + 1] == 'gpt-5.6-sol'
        assert 'model_reasoning_effort="medium"' in argv
        assert argv[-2] == '--' and str(folder / 'context.json') in argv[-1]
        config = json.loads(subprocess.check_output([argv[0], '-c', argv[4], 'mcp', 'get', 'omabib', '--json'], text=True))
        assert config['enabled'] and config['transport']['env']['OMABIB_SOCKET'] == sock, config
        assert config['transport']['args'] == ['mcp']
        desktop = runpy.run_path(str(Path(__file__).with_name('omabib-chatgpt')))
        desktop_folder, url = desktop['desktop_context'](sock, rid, project, root / 'desktop folders')
        query = parse_qs(urlparse(url).query)
        assert query['mode'] == ['codex'] and query['path'] == [str(desktop_folder.parent)]
        assert query['prompt'][0].startswith('$omabib\n')
        assert str(desktop_folder / 'context.json') in query['prompt'][0]
        desktop_config = tomllib.loads((desktop_folder.parent / '.codex/config.toml').read_text())
        assert desktop_config['model'] == 'gpt-5.6-sol'
        assert desktop_config['model_reasoning_effort'] == 'medium'
        assert desktop_config['mcp_servers']['omabib']['env']['OMABIB_SOCKET'] == sock
        assert (desktop_folder.parent / '.agents/skills/omabib/SKILL.md').is_file()
        print('PASS: all 28 notes, project scope, exact image bytes, PDF path, private context, and actual Codex MCP configuration')
    finally:
        service.terminate();service.wait(timeout=5)
