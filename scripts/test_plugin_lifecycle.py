#!/usr/bin/env python3
"""Test Omarchy's real add/update/remove scripts with isolated Git and shell IPC stubs."""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ID = 'io.github.atomashevic.omabib'


def run(*command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs)


def main():
    omarchy_bin = Path(shutil.which('omarchy-plugin-add')).resolve().parent
    with tempfile.TemporaryDirectory(prefix='omabib-lifecycle-') as temporary:
        scratch = Path(temporary)
        source, home, mocks = scratch / 'source', scratch / 'home', scratch / 'mocks'
        source.mkdir(); home.mkdir(); mocks.mkdir()
        shutil.copy2(ROOT / 'manifest.json', source / 'manifest.json')
        shutil.copytree(ROOT / 'plugin', source / 'plugin')
        run('git', 'init', '-q', str(source))
        run('git', '-C', str(source), 'config', 'user.name', 'Plugin Test')
        run('git', '-C', str(source), 'config', 'user.email', 'test@example.invalid')
        run('git', '-C', str(source), 'add', '.')
        run('git', '-C', str(source), 'commit', '-qm', 'Plugin fixture')
        for name in ('omarchy-plugin-catalog', 'omarchy-plugin-list'):
            file = mocks / name
            file.write_text('#!/bin/bash\necho "[]"\n')
            file.chmod(0o755)
        (mocks / 'omarchy-plugin-enable').write_text('#!/bin/bash\nprintf "%s\\n" "$1" > "$HOME/enabled"\n')
        (mocks / 'omarchy-plugin-enable').chmod(0o755)
        (mocks / 'omarchy-plugin-list').write_text(f'#!/bin/bash\necho \'[{{"id":"{PLUGIN_ID}"}}]\'\n')
        (mocks / 'omarchy-shell').write_text('#!/bin/bash\nif [[ "$2" == listPlugins ]]; then echo "[]"; else echo ok; fi\n')
        (mocks / 'omarchy-shell').chmod(0o755)
        url = 'https://github.com/atomashevic/omabib.git'
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   PATH=f'{mocks}:{omarchy_bin}:/usr/bin:/bin',
                   GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=f'url.{source}.insteadOf', GIT_CONFIG_VALUE_0=url)
        added = run(str(omarchy_bin / 'omarchy-plugin-add'), url, '--enable', '--yes', env=env)
        installed = home / '.config/omarchy/plugins' / PLUGIN_ID
        assert (installed / '.git').is_dir()
        assert (home / 'enabled').read_text().strip() == PLUGIN_ID
        (source / 'update.txt').write_text('update fixture')
        run('git', '-C', str(source), 'add', '.')
        run('git', '-C', str(source), 'commit', '-qm', 'Update fixture')
        run(str(omarchy_bin / 'omarchy-plugin-update'), PLUGIN_ID, '--yes', env=env)
        assert (installed / 'update.txt').read_text() == 'update fixture'
        assert not run('git', '-C', str(installed), 'status', '--porcelain').stdout.strip()
        run(str(omarchy_bin / 'omarchy-plugin-remove'), PLUGIN_ID, '--yes', env=env)
        assert not installed.exists()
        print('PASS: native Omarchy add --enable, validation, fast-forward update, and removal in an isolated home')


if __name__ == '__main__':
    main()
