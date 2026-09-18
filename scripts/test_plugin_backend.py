#!/usr/bin/env python3
"""Exercise plugin setup against a local release, never the user's desktop or library."""
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ID = 'io.github.atomashevic.omabib'


def tree_hash(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file()}


def main():
    archive = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='omabib-plugin-test-') as temporary:
        scratch = Path(temporary)
        home = scratch / 'home'
        plugin = home / '.config/omarchy/plugins' / PLUGIN_ID
        plugin.mkdir(parents=True)
        shutil.copy2(ROOT / 'manifest.json', plugin / 'manifest.json')
        (plugin / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/omabib-plugin', plugin / 'scripts/omabib-plugin')
        # Represent Omarchy's checkout, including an unrelated user customization.
        (plugin / '.git').mkdir()
        (plugin / '.git/HEAD').write_text('ref: refs/heads/main\n')
        (plugin / 'local-note.txt').write_text('keep this')
        commands = scratch / 'commands'
        commands.mkdir()
        for name in ('bash', 'dirname', 'mkdir', 'install', 'mv', 'rm', 'cp', 'touch', 'grep', 'python3'):
            (commands / name).symlink_to(sys.executable if name == 'python3' else shutil.which(name))
        for name in ('omarchy', 'omarchy-shell', 'systemctl'):
            path = commands / name
            path.write_text('#!/bin/bash\necho "$*" >> "$TEST_COMMAND_LOG"\n')
            path.chmod(0o755)
        env = dict(os.environ, HOME=str(home), PATH=str(commands), XDG_CONFIG_HOME=str(home / '.config'),
                   XDG_DATA_HOME=str(home / '.local/share'), XDG_STATE_HOME=str(home / '.local/state'),
                   TEST_COMMAND_LOG=str(scratch / 'commands.log'))
        helper = plugin / 'scripts/omabib-plugin'
        def call(action, *extra, success=True):
            result = subprocess.run(['python3', str(helper), action, *extra], env=env, capture_output=True, text=True)
            assert (result.returncode == 0) == success, (result.stdout, result.stderr)
            return json.loads(result.stdout)
        assert not call('status')['ready']
        legacy = home / '.config/omarchy/plugins/omabib'
        legacy.mkdir()
        (legacy / '.omabib-managed').touch()
        (legacy / 'keep.txt').write_text('old UI backup')
        original = tree_hash(plugin)
        assert call('install', '--archive', str(archive))['ready']
        assert call('status')['ready']
        assert tree_hash(plugin) == original, 'Backend install dirtied the plugin checkout'
        assert (legacy / 'keep.txt').read_text() == 'old UI backup'
        assert 'plugin disable omabib' in (scratch / 'commands.log').read_text()
        # Version changes must lead back to setup, rather than load a mismatched UI.
        m = json.loads((plugin / 'manifest.json').read_text())
        m['version'] = '9.9.9'
        (plugin / 'manifest.json').write_text(json.dumps(m))
        assert not call('status')['ready']
        shutil.copy2(ROOT / 'manifest.json', plugin / 'manifest.json')
        data = home / '.local/share/omabib/library.db'
        data.write_bytes(b'preserve library')
        assert call('remove-backend')['removed']
        assert data.read_bytes() == b'preserve library'
        assert not (home / '.local/bin/omabib').exists()
        assert tree_hash(plugin) == original
        assert not call('status')['ready']
        # Validate corrupted downloads and traversal before any installation can run.
        loader = importlib.machinery.SourceFileLoader('bootstrap', str(helper))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        checksum = scratch / 'SHA256SUMS'
        version = json.loads((ROOT / 'manifest.json').read_text())['version']
        checksum.write_text(f'{"0"*64}  {archive.name}\n')
        try:
            module.verify_and_extract(archive, checksum, scratch / 'bad', version)
            raise AssertionError('Accepted a corrupt checksum')
        except ValueError as error:
            assert 'incomplete or changed' in str(error)
        malicious = scratch / archive.name
        with tarfile.open(malicious, 'w:gz') as tar:
            info = tarfile.TarInfo(f'omabib-{version}-linux-x86_64/../../escape')
            info.size = 1
            tar.addfile(info, io.BytesIO(b'x'))
        checksum.write_text(f'{hashlib.sha256(malicious.read_bytes()).hexdigest()}  {archive.name}\n')
        try:
            module.verify_and_extract(malicious, checksum, scratch / 'bad', version)
            raise AssertionError('Accepted archive traversal')
        except ValueError as error:
            assert 'unsupported layout' in str(error)
        print('PASS: plugin setup, version gating, legacy migration, clean checkout, removal, checksum and archive rejection')


if __name__ == '__main__':
    main()
