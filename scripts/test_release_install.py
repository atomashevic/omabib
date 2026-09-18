#!/usr/bin/env python3
"""Exercise the real release installer in isolation; desktop/service commands are stubbed."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    archive = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='omabib-install-test-') as directory:
        root = Path(directory)
        with tarfile.open(archive) as tar:
            tar.extractall(root / 'unpacked', filter='data')
        package, = (root / 'unpacked').iterdir()
        home = root / 'home'
        home.mkdir()
        commands = root / 'commands'
        commands.mkdir()
        # A closed PATH makes any accidental compilation fail, even on CI build hosts.
        for name in ('bash', 'dirname', 'mkdir', 'install', 'mv', 'rm', 'cp', 'touch', 'grep', 'python3'):
            (commands / name).symlink_to(sys.executable if name == 'python3' else shutil.which(name))
        log = root / 'commands.log'
        for name in ('omarchy', 'omarchy-shell', 'systemctl'):
            command = commands / name
            command.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$TEST_COMMAND_LOG"\n')
            command.chmod(0o755)
        env = dict(os.environ, HOME=str(home), PATH=str(commands),
                   XDG_CONFIG_HOME=str(home / '.config'), XDG_DATA_HOME=str(home / '.local/share'),
                   XDG_STATE_HOME=str(home / '.local/state'), XDG_CACHE_HOME=str(home / '.cache'),
                   XDG_RUNTIME_DIR=str(root / 'runtime'), OMABIB_SOCKET=str(root / 'runtime/socket'),
                   OMABIB_DB=str(home / '.local/share/omabib/library.db'), TEST_COMMAND_LOG=str(log))
        Path(env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
        env.pop('CARGO_TARGET_DIR', None)
        settings = home / '.config/omabib/settings.json'
        settings.parent.mkdir(parents=True)
        settings.write_text('{"ai_cli":"claude"}\n')
        installer = package / 'scripts/install.sh'
        for _ in range(2):
            subprocess.run([str(installer)], env=env, check=True, capture_output=True, text=True)
        installed = home / '.local/bin/omabib'
        assert digest(installed) == digest(package / 'bin/omabib')
        for source in (package / 'plugin').rglob('*'):
            if source.is_file():
                assert digest(source) == digest(home / '.config/omarchy/plugins/io.github.atomashevic.omabib/plugin' / source.relative_to(package / 'plugin'))
        for source in (package / 'scripts').glob('omabib-*'):
            destination = (home / '.config/omarchy/plugins/io.github.atomashevic.omabib/scripts' / source.name
                           if source.name == 'omabib-plugin' else home / '.local/bin' / source.name)
            assert digest(source) == digest(destination)
        assert (home / '.local/share/omabib/licenses/THIRD-PARTY.md').is_file()
        assert (home / '.config/systemd/user/omabib.service').read_bytes() == (package / 'packaging/omabib.service').read_bytes()
        assert (home / '.codex/skills/omabib/SKILL.md').is_file()
        for invocation in ('daemon-reload', 'enable --now omabib.service', 'restart omabib.service',
                           'shell rescanPlugins', 'plugin enable io.github.atomashevic.omabib'):
            assert invocation in log.read_text(), invocation
        # Run the installed backend itself with an isolated library and real Unix socket.
        with (root / 'service.log').open('w') as service_log:
            service = subprocess.Popen([str(installed), 'serve'], env=env, stdout=service_log, stderr=service_log)
            try:
                for _ in range(100):
                    status = subprocess.run([str(installed), 'status'], env=env, capture_output=True, text=True)
                    if status.returncode == 0:
                        break
                    if service.poll() is not None:
                        raise AssertionError((root / 'service.log').read_text())
                    time.sleep(0.1)
                assert status.returncode == 0, status.stderr
                json.loads(status.stdout)
            finally:
                service.terminate()
                service.wait(timeout=10)
        database = Path(env['OMABIB_DB'])
        original_db = digest(database)
        subprocess.run([str(installer)], env=env, check=True, capture_output=True)
        assert digest(database) == original_db, 'Reinstall changed the library'
        assert settings.read_text() == '{"ai_cli":"claude"}\n'
        marker = home / '.config/omarchy/plugins/io.github.atomashevic.omabib/.omabib-managed'
        marker.unlink()
        previous_log = log.read_text()
        result = subprocess.run([str(installer)], env=env, capture_output=True, text=True)
        assert result.returncode != 0 and 'unmanaged' in result.stderr
        assert log.read_text() == previous_log
        marker.touch()
        payload = package / 'bin/omabib'
        payload.rename(package / 'bin/omabib.saved')
        result = subprocess.run([str(installer)], env=env, capture_output=True, text=True)
        assert result.returncode != 0 and 'No executable' in result.stderr
        assert log.read_text() == previous_log
        (package / 'bin/omabib.saved').rename(payload)
        # Missing payload must fail before it touches an existing installation.
        (package / 'scripts/omabib-settings').unlink()
        previous_log = log.read_text()
        result = subprocess.run([str(installer)], env=env, capture_output=True, text=True)
        assert result.returncode != 0 and 'Package is missing' in result.stderr
        assert digest(installed) == digest(package / 'bin/omabib')
        assert log.read_text() == previous_log
        print('PASS: compiler-free install, reinstall, payload hashes, isolated backend, library/settings preservation, unmanaged-plugin and incomplete-package rejection')


if __name__ == '__main__':
    main()
