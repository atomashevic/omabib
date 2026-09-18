#!/usr/bin/env python3
"""Verify consolidated MCP setup with the real Codex CLI and an isolated profile."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    codex = shutil.which('codex')
    if not codex:
        raise SystemExit('This integration test requires Codex CLI.')
    with tempfile.TemporaryDirectory(prefix='omabib-mcp-setup-') as directory:
        root = Path(directory)
        home, profile, commands = root / 'home', root / 'codex-profile', root / 'bin'
        home.mkdir(); profile.mkdir(); commands.mkdir()
        binary = commands / 'omabib'
        binary.write_text('#!/bin/bash\n[[ "$1" == status ]]\n')
        binary.chmod(0o755)
        env = dict(os.environ, HOME=str(home), CODEX_HOME=str(profile), OMABIB_SOCKET=str(root / 'library/socket'),
                   XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   PATH=f'{commands}:{os.environ["PATH"]}')
        config = profile / 'config.toml'
        config.write_text('model = "test-model"\n[mcp_servers.unrelated]\ncommand = "/bin/true"\nargs = []\n')
        installed_helper = commands / 'omabib-settings'
        shutil.copy2(ROOT / 'scripts/omabib-settings', installed_helper)
        bundled_skill = root / 'data/omabib/skills/omabib/SKILL.md'
        bundled_skill.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'skills/omabib/SKILL.md', bundled_skill)
        helper = [sys.executable, str(installed_helper)]
        def settings(*args, success=True):
            p = subprocess.run([*helper, *args], env=env, capture_output=True, text=True, cwd=home)
            assert (p.returncode == 0) == success, p.stdout + p.stderr
            return json.loads(p.stdout)
        assert settings()['codex_mcp']['state'] == 'missing'
        assert settings('register-codex')['codex_mcp']['state'] == 'connected'
        source = ROOT / 'skills/omabib/SKILL.md'
        destination = profile / 'skills/omabib/SKILL.md'
        assert destination.read_bytes() == source.read_bytes()
        original = config.read_bytes()
        destination.write_text('old companion skill')
        assert settings('register-codex')['codex_mcp']['state'] == 'connected'
        assert config.read_bytes() == original, 'Idempotent setup rewrote Codex configuration'
        assert destination.read_bytes() == source.read_bytes()
        assert 'unrelated' in config.read_text() and 'test-model' in config.read_text()
        mismatch = str(root / 'other-library/socket')
        assert 'different' in settings('register-codex', mismatch, success=False)['error']
        assert config.read_bytes() == original
        # Disabled registrations are deliberately preserved.
        config.write_text(config.read_text().replace('[mcp_servers.omabib]', '[mcp_servers.omabib]\nenabled = false'))
        disabled = config.read_bytes()
        assert settings()['codex_mcp']['state'] == 'custom'
        settings('register-codex', success=False)
        assert config.read_bytes() == disabled
        # A broken config must not be interpreted as an absent registration.
        config.write_text('this is invalid toml = [')
        assert settings()['codex_mcp']['state'] == 'error'
        settings('register-codex', success=False)
        assert config.read_text() == 'this is invalid toml = ['
        print('PASS: real Codex registration/readback, custom CODEX_HOME, skill refresh, idempotency, and preservation of custom/disabled/broken configuration')


if __name__ == '__main__':
    main()
