#!/usr/bin/env python3
"""Verify Claude Code setup and connect-agents with the real Claude Code CLI and a temporary home.

Usage: scripts/test_agent_setup.py [CLAUDE]. CLAUDE defaults to the claude on PATH;
pass the real binary when that is a wrapper that needs the user's home (mise).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    claude = sys.argv[1] if len(sys.argv) > 1 else shutil.which('claude')
    if not claude:
        raise SystemExit('This integration test requires Claude Code.')
    with tempfile.TemporaryDirectory(prefix='omabib-agent-setup-') as directory:
        root = Path(directory)
        home, commands = root / 'home', root / 'bin'
        home.mkdir(); commands.mkdir()
        binary = commands / 'omabib'
        binary.write_text('#!/bin/bash\n[[ "$1" == status ]]\n')
        binary.chmod(0o755)
        (commands / 'claude').symlink_to(os.path.realpath(claude))
        socket = str(root / 'library/socket')
        # PATH is only this folder: no Codex or Claude Desktop from the host, so
        # Codex is reported and left alone, and Claude Desktop is found by its config folder.
        env = dict(HOME=str(home), OMABIB_SOCKET=socket, PATH=str(commands),
                   XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1')
        bundled_skill = root / 'data/omabib/skills/omabib/SKILL.md'
        bundled_skill.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'skills/omabib/SKILL.md', bundled_skill)
        installed_helper = commands / 'omabib-settings'
        shutil.copy2(ROOT / 'scripts/omabib-settings', installed_helper)

        def settings(*args, success=True, extra=None):
            p = subprocess.run([sys.executable, str(installed_helper), *args], env=dict(env, **(extra or {})),
                               capture_output=True, text=True, cwd=home, timeout=120)
            assert (p.returncode == 0) == success, p.stdout + p.stderr
            return json.loads(p.stdout)

        def states(shown):
            return {agent['id']: agent['state'] for agent in shown['agents']}

        assert states(settings()) == {'claude-code': 'missing', 'codex': 'unavailable', 'claude-desktop': 'unavailable'}
        # Claude Desktop counts as installed once its config folder exists.
        (root / 'config/Claude').mkdir(parents=True)
        assert states(settings())['claude-desktop'] == 'missing'

        shown = settings('connect-agents')
        assert states(shown) == {'claude-code': 'connected', 'codex': 'unavailable', 'claude-desktop': 'connected'}, shown['agents']
        assert shown['settings']['agent_setup'] == 'done'
        config = home / '.claude.json'
        server = json.loads(config.read_text())['mcpServers']['omabib']
        assert server == {'type': 'stdio', 'command': str(binary), 'args': ['mcp'], 'env': {'OMABIB_SOCKET': socket}}, server
        listed = subprocess.run(['claude', 'mcp', 'get', 'omabib'], env=env, capture_output=True, text=True, timeout=120)
        assert listed.returncode == 0 and 'omabib' in listed.stdout, listed.stdout + listed.stderr
        skill = home / '.claude/skills/omabib/SKILL.md'
        assert skill.read_bytes() == (ROOT / 'skills/omabib/SKILL.md').read_bytes()
        desktop = json.loads((root / 'config/Claude/claude_desktop_config.json').read_text())
        assert desktop['mcpServers']['omabib']['args'] == ['mcp']

        # Running again changes nothing that is already connected, but refreshes the skill.
        original = config.read_bytes()
        skill.write_text('old skill')
        assert states(settings('connect-agents'))['claude-code'] == 'connected'
        assert config.read_bytes() == original, 'connect-agents rewrote a connected Claude Code'
        assert skill.read_text() == 'old skill', 'connect-agents only touches agents without a connection'
        assert settings('register-claude-code')['agents'][0]['state'] == 'connected'
        assert config.read_bytes() == original, 'register-claude-code rewrote a connected Claude Code'
        assert skill.read_bytes() == (ROOT / 'skills/omabib/SKILL.md').read_bytes()

        # Another library's connection is left alone.
        other = settings(extra={'OMABIB_SOCKET': str(root / 'other/socket')})
        assert states(other)['claude-code'] == 'custom'
        settings('register-claude-code', str(root / 'other/socket'), success=False)
        failed = settings('connect-agents', str(root / 'other/socket'))
        assert states(failed)['claude-code'] == 'custom'
        assert config.read_bytes() == original

        # A broken file is not taken for a missing connection.
        config.write_text('{ not json')
        assert states(settings())['claude-code'] == 'error'
        settings('register-claude-code', success=False)
        assert config.read_text() == '{ not json'

        # CLAUDE_CONFIG_DIR moves both the settings file and the skills folder.
        moved = root / 'claude-config'
        moved.mkdir()
        extra = {'CLAUDE_CONFIG_DIR': str(moved)}
        assert states(settings(extra=extra))['claude-code'] == 'missing'
        assert states(settings('register-claude-code', extra=extra))['claude-code'] == 'connected'
        assert json.loads((moved / '.claude.json').read_text())['mcpServers']['omabib']['command'] == str(binary)
        assert (moved / 'skills/omabib/SKILL.md').is_file()
        print('PASS: real Claude Code registration and readback, skill install, connect-agents across agents, '
              'idempotency, CLAUDE_CONFIG_DIR, and preservation of other and broken configuration')


if __name__ == '__main__':
    main()
