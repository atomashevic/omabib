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
REMOVE_HINT = f'omarchy plugin remove {PLUGIN_ID}'


def tree_hash(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file()}


def run_remove(helper, env):
    result = subprocess.run(['python3', str(helper), 'remove-backend'], env=env, capture_output=True, text=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    payload = json.loads(result.stdout)
    assert payload['removed'] is True
    return result, payload


def test_uninstall():
    """Temp HOME, fake systemctl and omarchy. No library, account, or Drive folder."""
    helper = ROOT / 'scripts/omabib-plugin'
    with tempfile.TemporaryDirectory(prefix='omabib-uninstall-') as temporary:
        scratch = Path(temporary)
        home = scratch / 'home'
        commands = scratch / 'commands'
        commands.mkdir(parents=True)
        log = scratch / 'commands.log'
        for name in ('systemctl', 'omarchy'):
            path = commands / name
            path.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$TEST_COMMAND_LOG"\n')
            path.chmod(0o755)
        (commands / 'python3').symlink_to(sys.executable)
        env = dict(os.environ, HOME=str(home), PATH=str(commands),
                   XDG_CONFIG_HOME=str(home / '.config'),
                   XDG_DATA_HOME=str(home / '.local/share'),
                   XDG_STATE_HOME=str(home / '.local/state'),
                   OMABIB_DESKTOP_SOCKET=str(scratch / 'desktop.sock'),
                   TEST_COMMAND_LOG=str(log))
        plugin = home / '.config/omarchy/plugins' / PLUGIN_ID
        plugin.mkdir(parents=True)
        (plugin / '.omabib-managed').write_text('managed\n')
        (plugin / 'plugin').mkdir()
        (plugin / 'plugin/App.qml').write_text('managed copy\n')
        unmarked = home / '.config/omarchy/plugins/omabib'
        unmarked.mkdir()
        (unmarked / 'keep.txt').write_text('leave unmarked plugins\n')
        unit = home / '.config/systemd/user/omabib.service'
        unit.parent.mkdir(parents=True)
        unit.write_text('[Service]\nExecStart=/bin/true\n')
        library = home / '.local/share/omabib/library.db'
        library.parent.mkdir(parents=True)
        library.write_bytes(b'preserve library')
        settings = home / '.config/omabib/settings.json'
        settings.parent.mkdir(parents=True)
        settings.write_text('{"theme":"system"}\n')
        bindir = home / '.local/bin'
        bindir.mkdir(parents=True)
        quit_log = scratch / 'quit.log'
        desktop = bindir / 'omabib-desktop'
        desktop.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{quit_log}"\n')
        desktop.chmod(0o755)
        for name in ('omabib', 'omabib-settings'):
            binary = bindir / name
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
        (bindir / 'not-omabib').write_text('keep\n')
        (home / '.local/lib/omabib/bin').mkdir(parents=True)
        (home / '.local/lib/omabib/bin/omabib').write_text('bundled\n')
        applications = home / '.local/share/applications'
        applications.mkdir(parents=True)
        (applications / 'omabib.desktop').write_text('[Desktop Entry]\nExec=omabib-desktop\n')
        (home / '.local/share/icons/hicolor/48x48/apps').mkdir(parents=True)
        (home / '.local/share/icons/hicolor/48x48/apps/omabib.png').write_bytes(b'png')
        (home / '.local/share/icons/hicolor/scalable/apps').mkdir(parents=True)
        (home / '.local/share/icons/hicolor/scalable/apps/omabib.svg').write_text('<svg/>\n')

        result, _payload = run_remove(helper, env)
        recorded = log.read_text().splitlines()
        assert any(line.endswith('systemctl --user disable --now omabib.service') for line in recorded)
        assert any(line.endswith('systemctl --user daemon-reload') for line in recorded)
        disable_at = next(i for i, line in enumerate(recorded) if 'disable --now' in line)
        reload_at = next(i for i, line in enumerate(recorded) if 'daemon-reload' in line)
        assert disable_at < reload_at
        assert not any('omarchy' in line for line in recorded)
        assert quit_log.read_text().strip() == '--quit'
        assert not unit.exists()
        assert not plugin.exists()
        assert library.read_bytes() == b'preserve library'
        assert settings.read_text() == '{"theme":"system"}\n'
        assert (unmarked / 'keep.txt').read_text() == 'leave unmarked plugins\n'
        assert not (bindir / 'omabib').exists()
        assert not (bindir / 'omabib-settings').exists()
        assert not desktop.exists()
        assert (bindir / 'not-omabib').read_text() == 'keep\n'
        assert not (home / '.local/lib/omabib').exists()
        assert not (applications / 'omabib.desktop').exists()
        assert not list((home / '.local/share/icons').glob('hicolor/*/apps/omabib.*'))
        assert result.stderr == ''

        plugin.mkdir(parents=True)
        (plugin / 'user-edit.txt').write_text('no marker\n')
        log.write_text('')
        result, _payload = run_remove(helper, env)
        assert (plugin / 'user-edit.txt').read_text() == 'no marker\n'
        assert not (plugin / '.git').exists()
        assert result.stderr == ''
        assert log.read_text() == ''
        assert library.read_bytes() == b'preserve library'

        (plugin / '.git').mkdir()
        (plugin / '.git/HEAD').write_text('ref: refs/heads/main\n')
        (plugin / '.omabib-managed').write_text('do not trust this beside .git\n')
        result, payload = run_remove(helper, env)
        assert (plugin / 'user-edit.txt').read_text() == 'no marker\n'
        assert (plugin / '.git/HEAD').is_file()
        assert (plugin / '.omabib-managed').is_file()
        assert result.stderr == REMOVE_HINT + '\n'
        assert REMOVE_HINT in payload['message']
        assert library.read_bytes() == b'preserve library'
        assert settings.read_text() == '{"theme":"system"}\n'

    with tempfile.TemporaryDirectory(prefix='omabib-uninstall-clean-') as temporary:
        scratch = Path(temporary)
        home = scratch / 'home'
        home.mkdir()
        commands = scratch / 'commands'
        commands.mkdir()
        log = scratch / 'commands.log'
        log.write_text('')
        systemctl = commands / 'systemctl'
        systemctl.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$TEST_COMMAND_LOG"\nexit 1\n')
        systemctl.chmod(0o755)
        (commands / 'python3').symlink_to(sys.executable)
        env = dict(os.environ, HOME=str(home), PATH=str(commands),
                   XDG_CONFIG_HOME=str(home / '.config'),
                   XDG_DATA_HOME=str(home / '.local/share'),
                   XDG_STATE_HOME=str(home / '.local/state'),
                   TEST_COMMAND_LOG=str(log))
        run_remove(helper, env)
        run_remove(helper, env)
        assert log.read_text() == ''
        assert not (home / '.local/share/omabib').exists()
        assert not (home / '.config/omabib').exists()
    print('PASS: uninstall removes the service and a managed plugin, keeps an unmarked plugin and the library')


def main():
    test_uninstall()
    if len(sys.argv) == 1:
        return
    if len(sys.argv) != 2:
        raise SystemExit(f'usage: {sys.argv[0]} [ARCHIVE]')
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
        for name in ('bash', 'dirname', 'mkdir', 'install', 'mv', 'rm', 'cp', 'touch', 'grep', 'ln', 'uname', 'python3'):
            (commands / name).symlink_to(sys.executable if name == 'python3' else shutil.which(name))
        for name in ('omarchy', 'omarchy-shell', 'systemctl'):
            path = commands / name
            path.write_text('#!/bin/bash\necho "$*" >> "$TEST_COMMAND_LOG"\n')
            path.chmod(0o755)
        env = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / ".codex"), PATH=str(commands), XDG_CONFIG_HOME=str(home / '.config'),
                   XDG_DATA_HOME=str(home / '.local/share'), XDG_STATE_HOME=str(home / '.local/state'),
                   OMABIB_DESKTOP_SOCKET=str(scratch / 'desktop.sock'),
                   TEST_COMMAND_LOG=str(scratch / 'commands.log'))
        helper = plugin / 'scripts/omabib-plugin'
        captured = {}
        def call(action, *extra, success=True):
            result = subprocess.run(['python3', str(helper), action, *extra], env=env, capture_output=True, text=True)
            captured['stdout'] = result.stdout
            captured['stderr'] = result.stderr
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
        # An archive that bundles the app installs it, and the plugin then
        # hands Omabib to it; without one, it reports the app once it appears.
        app = home / '.local/bin/omabib-desktop'
        bundled = app.exists()
        assert call('status')['desktop'] == (str(app) if bundled else '')
        if not bundled:
            app.write_text('#!/bin/sh\n')
            app.chmod(0o755)
            assert call('status')['desktop'] == str(app)
            app.unlink()
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
        log = scratch / 'commands.log'
        before = log.read_text()
        removed = call('remove-backend')
        assert removed['removed']
        assert REMOVE_HINT in removed['message']
        assert captured['stderr'] == REMOVE_HINT + '\n'
        recorded = log.read_text()[len(before):]
        assert 'disable --now' in recorded and 'daemon-reload' in recorded
        assert recorded.find('disable --now') < recorded.find('daemon-reload')
        assert not (home / '.config/systemd/user/omabib.service').exists()
        assert data.read_bytes() == b'preserve library'
        assert not (home / '.local/bin/omabib').exists()
        assert not app.is_symlink() and not app.exists() and not (home / '.local/lib/omabib').exists()
        assert not (home / '.local/share/applications/omabib.desktop').exists()
        assert not list((home / '.local/share/icons').glob('hicolor/*/apps/omabib.*'))
        assert tree_hash(plugin) == original
        assert (legacy / 'keep.txt').read_text() == 'old UI backup'
        before = log.read_text()
        assert call('remove-backend')['removed']
        assert 'disable --now' not in log.read_text()[len(before):]
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
