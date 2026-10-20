#!/usr/bin/env python3
"""Hyprland key install: one marked block, and no palette shortcut that is not bound.

Uses a temporary HOME, a fake omabib, and a fake omarchy. Never a real library.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIND = 'o.bind("SUPER + ALT + B", "Omabib", "omabib open")'
MARKER = '-- omabib-keybind'
HEADER = (
    '-- Keep only your personal keybinding overrides here. Add new bindings with\n'
    '-- o.bind or replace defaults with o.rebind.\n'
)
BLOCK = f'{MARKER}\n{BIND}\n'
CREATED = f'{HEADER}\n{BLOCK}'
TOLD = f'Show or hide Omabib with Super + Alt + B: {BIND}'
LEFT = 'already uses Super + Alt + B and has no Omabib marker'


def closed_commands(directory, omarchy):
    directory.mkdir()
    names = (
        'bash', 'dirname', 'mkdir', 'install', 'mv', 'rm', 'cp', 'touch',
        'grep', 'ln', 'uname', 'python3', 'tail',
    )
    for name in names:
        target = sys.executable if name == 'python3' else shutil.which(name)
        if target is None:
            raise SystemExit(f'missing {name}')
        (directory / name).symlink_to(target)
    if omarchy:
        path = directory / 'omarchy'
        path.write_text('#!/bin/sh\nexit 0\n')
        path.chmod(0o755)
    binary = directory / 'omabib'
    binary.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then echo omabib 0.0.0; fi\nexit 0\n')
    binary.chmod(0o755)
    return binary


def run_install(home, commands, binary):
    env = dict(
        os.environ,
        HOME=str(home),
        CODEX_HOME=str(home / '.codex'),
        PATH=str(commands),
        XDG_CONFIG_HOME=str(home / '.config'),
        XDG_DATA_HOME=str(home / '.local/share'),
        XDG_STATE_HOME=str(home / '.local/state'),
        XDG_CACHE_HOME=str(home / '.cache'),
    )
    env.pop('CARGO_TARGET_DIR', None)
    return subprocess.run(
        [str(ROOT / 'scripts/install.sh'), str(binary)],
        env=env, capture_output=True, text=True,
    )


def bindings(home):
    return home / '.config/hypr/bindings.lua'


def main():
    palette = (ROOT / 'plugin/components/CommandPalette.qml').read_text()
    if 'Super+Alt+B' in palette:
        raise SystemExit('CommandPalette.qml still shows Super+Alt+B')

    with tempfile.TemporaryDirectory(prefix='omabib-keybind-') as temporary:
        scratch = Path(temporary)

        # Missing file: two installs write one block, and the output names the line.
        home = scratch / 'fresh'
        home.mkdir()
        commands = scratch / 'with-omarchy'
        binary = closed_commands(commands, omarchy=True)
        first = run_install(home, commands, binary)
        assert first.returncode == 0, first.stderr
        assert TOLD in first.stdout, first.stdout
        assert bindings(home).read_text() == CREATED
        second = run_install(home, commands, binary)
        assert second.returncode == 0, second.stderr
        assert TOLD in second.stdout, second.stdout
        text = bindings(home).read_text()
        assert text == CREATED
        assert text.count(MARKER) == 1
        assert text.count(BIND) == 1

        # The chord is already bound, and our marker is absent: leave the file alone.
        home = scratch / 'taken'
        home.mkdir()
        path = bindings(home)
        path.parent.mkdir(parents=True)
        original = (
            '-- mine\n'
            'o.bind("SUPER + ALT + B", "Private", "firefox")\n'
            'o.bind("SUPER + SHIFT + T", "Terminal", "alacritty")\n'
        )
        path.write_text(original)
        taken = run_install(home, commands, binary)
        assert taken.returncode == 0, taken.stderr
        assert path.read_text() == original
        assert LEFT in taken.stdout, taken.stdout
        assert MARKER not in path.read_text()
        assert TOLD not in taken.stdout

        # Same chord, different spacing and case, still left alone.
        home = scratch / 'compact'
        home.mkdir()
        path = bindings(home)
        path.parent.mkdir(parents=True)
        compact = 'o.bind("super+alt+b", "Mine", "true")\n'
        path.write_text(compact)
        compact_run = run_install(home, commands, binary)
        assert compact_run.returncode == 0, compact_run.stderr
        assert path.read_text() == compact
        assert LEFT in compact_run.stdout

        # A comment and a longer chord are not this binding. Append once.
        home = scratch / 'append'
        home.mkdir()
        path = bindings(home)
        path.parent.mkdir(parents=True)
        existing = (
            '-- o.bind("SUPER + ALT + B", "Example", "echo")\n'
            'o.bind("SUPER + SHIFT + ALT + B", "Browser", "chromium")\n'
            'o.bind("SUPER + CTRL + B", "Bluetooth", "omarchy-menu bluetooth")'
        )
        path.write_text(existing)
        appended = run_install(home, commands, binary)
        assert appended.returncode == 0, appended.stderr
        assert TOLD in appended.stdout
        expect = existing + '\n\n' + BLOCK
        assert path.read_text() == expect
        again = run_install(home, commands, binary)
        assert again.returncode == 0, again.stderr
        assert path.read_text() == expect
        assert path.read_text().count(MARKER) == 1

        # No omarchy on PATH: do not invent a bindings file.
        home = scratch / 'plain'
        home.mkdir()
        plain_bin = scratch / 'plain-commands'
        binary = closed_commands(plain_bin, omarchy=False)
        plain = run_install(home, plain_bin, binary)
        assert plain.returncode == 0, plain.stderr
        assert not bindings(home).exists()
        assert MARKER not in plain.stdout
        assert 'Super + Alt + B' not in plain.stdout

    print('PASS: one Hyprland block, existing chord left alone, palette has no Super+Alt+B')


if __name__ == '__main__':
    main()
