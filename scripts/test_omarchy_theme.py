#!/usr/bin/env python3
"""Omarchy theme following, with a temporary HOME and fixture files only.

Checks omabib-settings, then the offscreen QML palette (QT_QPA_PLATFORM=offscreen).
No library, no cloud account, no Google Drive folder.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / 'scripts/omabib-settings'
DARK = """mode = "dark"
background = "#f4f1ea"
foreground = "#1c1915"
accent = "#aa3300"
red = "#cc2211"
muted = "#8a8175"
"""


def run_settings(*args, env):
    result = subprocess.run([sys.executable, str(SETTINGS), *args], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout)


def check_settings():
    with tempfile.TemporaryDirectory(prefix='omabib-theme-') as directory:
        home = Path(directory)
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'))
        shown = run_settings(env=env)
        assert shown['settings']['theme'] == 'system', shown
        assert not (home / '.config/omabib/settings.json').exists()

        colors = home / '.local/state/omarchy/current/theme/colors.toml'
        colors.parent.mkdir(parents=True)
        colors.write_text('mode = "light"\nnot a palette\n')
        shown = run_settings(env=env)
        assert shown['settings']['theme'] == 'system', shown

        colors.write_text('color0 = "#111111"\ncolor7 = "#eeeeee"\n')
        shown = run_settings(env=env)
        assert shown['settings']['theme'] == 'omarchy', shown
        assert not (home / '.config/omabib/settings.json').exists()

        colors.write_text(DARK)
        for choice in ('system', 'light', 'dark'):
            path = home / '.config/omabib/settings.json'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({'theme': choice, 'reading_font': 'serif'}) + '\n')
            before = path.read_text()
            shown = run_settings(env=env)
            assert shown['settings']['theme'] == choice, shown
            assert shown['settings']['reading_font'] == 'serif', shown
            assert path.read_text() == before

        path.write_text(json.dumps({'reading_font': 'serif'}) + '\n')
        shown = run_settings(env=env)
        assert shown['settings']['theme'] == 'omarchy', shown
        assert shown['settings']['reading_font'] == 'serif', shown
        assert json.loads(path.read_text()) == {'reading_font': 'serif'}

        shown = run_settings('set', 'pdf_colors', 'theme', env=env)
        assert shown['settings']['theme'] == 'omarchy', shown
        assert shown['settings']['pdf_colors'] == 'theme', shown
        stored = json.loads(path.read_text())
        assert stored['theme'] == 'omarchy' and stored['reading_font'] == 'serif' and stored['pdf_colors'] == 'theme'

        path.write_text(json.dumps({'theme': 'dark'}) + '\n')
        shown = run_settings('set', 'reading_font', 'serif', env=env)
        assert json.loads(path.read_text())['theme'] == 'dark'

        colors.unlink()
        path.write_text(json.dumps({'theme': 'omarchy'}) + '\n')
        shown = run_settings(env=env)
        assert shown['settings']['theme'] == 'omarchy', shown
    print('PASS: a new config follows a parsed Omarchy theme, and an explicit theme stays', flush=True)


def check_qml():
    # The Quickshell modules are static libraries. qmltestrunner cannot load
    # them, so the check is the same Quick Test runner linked to those libraries.
    runner = ROOT / 'build/desktop/tst_omarchy_theme'
    if not runner.is_file():
        raise SystemExit(f'Missing {runner}. Build it with cmake --build build/desktop --target tst_omarchy_theme.')
    with tempfile.TemporaryDirectory(prefix='omabib-theme-qml-') as directory:
        home = Path(directory)
        colors = home / '.local/state/omarchy/current/theme/colors.toml'
        colors.parent.mkdir(parents=True)
        colors.write_text(DARK)
        env = dict(os.environ, HOME=str(home), QT_QPA_PLATFORM='offscreen')
        env.pop('QT_QPA_PLATFORMTHEME', None)
        command = [str(runner)]
        print('RUN:', 'QT_QPA_PLATFORM=offscreen', 'HOME=' + str(home), *command, flush=True)
        result = subprocess.run(command, env=env, cwd=ROOT, text=True)
        if result.returncode != 0:
            raise SystemExit(result.returncode)
    print('PASS: offscreen Omarchy swatch follows a replaced theme directory', flush=True)


if __name__ == '__main__':
    check_settings()
    check_qml()
