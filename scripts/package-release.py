#!/usr/bin/env python3
"""Package an already-built omabib, the app bundled by scripts/bundle-*-app, licenses, and optional vendored source."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPERS = (
    'omabib-close-first', 'omabib-chatgpt', 'omabib-codex',
    'omabib-overview', 'omabib-settings', 'omabib-claude',
)
PLATFORMS = {
    'linux-x86_64': 'Linux x86-64 (glibc 2.35 or newer: Ubuntu 22.04, Debian 12, Fedora 36 and later, Arch)',
    'macos-arm64': 'macOS 13 or newer on Apple silicon',
}


def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def archive(directory, output):
    with tarfile.open(output, 'w:gz') as tar:
        tar.add(directory, arcname=directory.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True, help='Release tag, e.g. v0.1.0')
    parser.add_argument('--binary', type=Path, default=ROOT / 'target/release/omabib')
    parser.add_argument('--output', type=Path, default=ROOT / 'target/dist')
    parser.add_argument('--source', action='store_true', help='Also archive clean HEAD and vendored dependencies')
    parser.add_argument('--platform', choices=PLATFORMS, default='linux-x86_64')
    parser.add_argument('--app', type=Path, help='The app staged by scripts/bundle-linux-app or bundle-macos-app')
    args = parser.parse_args()
    version = args.version.removeprefix('v')
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        parser.error('version must be a semantic version, optionally prefixed with v')
    cargo_version = tomllib.loads((ROOT / 'Cargo.toml').read_text())['package']['version']
    plugin_version = json.loads((ROOT / 'manifest.json').read_text())['version']
    app_version = re.search(r'project\(omabib-desktop VERSION (\S+)', (ROOT / 'desktop/CMakeLists.txt').read_text())[1]
    if not version == cargo_version == plugin_version == app_version:
        parser.error('release tag, Cargo.toml, manifest.json, and desktop/CMakeLists.txt versions must match')
    binary = args.binary.resolve()
    header = binary.read_bytes()[:20]
    if args.platform == 'linux-x86_64' and (header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\x3e\x00'):
        parser.error('binary must be a little-endian x86-64 ELF executable')
    if args.platform == 'macos-arm64' and header[:8] != b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01':
        parser.error('binary must be an arm64 Mach-O executable')
    if run(str(binary), '--version').strip() != f'omabib {version}':
        parser.error('binary version does not match the release version')
    if args.platform == 'macos-arm64' and not (args.app and (args.app / 'Omabib.app').is_dir()):
        parser.error('macOS releases need --app with Omabib.app')
    if args.source and run('git', 'status', '--porcelain').strip():
        parser.error('--source requires a clean checkout so source and release files agree')
    metadata = json.loads(run('cargo', 'metadata', '--locked', '--format-version', '1'))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = f'omabib-{version}-{args.platform}'
    artifacts = []
    with tempfile.TemporaryDirectory(prefix='omabib-release-') as temporary:
        stage = Path(temporary) / name
        for file in ('README.md', 'LICENSE', 'API.md', 'scripts/install.sh', 'skills/omabib/SKILL.md'):
            copy(ROOT / file, stage / file)
        for file in (ROOT / 'plugin/components/fonts').iterdir():
            if not file.name.endswith('.ttf'):
                copy(file, stage / 'licenses/fonts' / file.name)
        if args.app and (args.app / 'licenses').is_dir():
            shutil.copytree(args.app / 'licenses', stage / 'licenses', dirs_exist_ok=True)
        if args.platform == 'macos-arm64':
            # The bundle's frameworks are links into themselves; keep them so.
            bundled = args.app / 'Omabib.app/Contents/MacOS/omabib'
            if bundled.read_bytes() != binary.read_bytes():
                parser.error('Omabib.app holds a different omabib than --binary')
            shutil.copytree(args.app / 'Omabib.app', stage / 'Omabib.app', symlinks=True)
        else:
            copy(binary, stage / 'bin/omabib')
            if args.app:
                # The app and its own Qt; no links, which the plugin's installer refuses.
                for part in ('bin', 'lib', 'plugins', 'qml'):
                    shutil.copytree(args.app / part, stage / part, dirs_exist_ok=True)
                copy(ROOT / 'packaging/omabib.desktop', stage / 'share/applications/omabib.desktop')
                copy(ROOT / 'packaging/omabib.svg', stage / 'share/icons/hicolor/scalable/apps/omabib.svg')
            for file in ('packaging/omabib.service', 'scripts/omabib-plugin', 'manifest.json'):
                copy(ROOT / file, stage / file)
            for helper in HELPERS:
                copy(ROOT / 'scripts' / helper, stage / 'scripts' / helper)
            legacy_helper = ROOT / 'scripts/omabib-history'
            if legacy_helper.is_file():
                copy(legacy_helper, stage / 'scripts/omabib-history')
            shutil.copytree(ROOT / 'plugin', stage / 'plugin')
        copy(ROOT / 'src/mitex/LICENSE', stage / 'licenses/embedded-mitex/LICENSE')
        inventory = ['# Third-party notices', '',
                     'License expressions and bundled notices for the locked dependency graph.',
                     'Includes build-time and platform-specific dependencies.', '',
                     '| Crate | License expression | Source |', '|---|---|---|']
        for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
            if package['source'] is None:
                continue
            crate = f"{package['name']}-{package['version']}"
            inventory.append(f"| {crate} | {package.get('license') or 'See bundled notices'} | {package.get('repository') or package['source']} |")
            directory = Path(package['manifest_path']).parent
            # Retain native dependency notices too, especially MuPDF's bundled libraries.
            for path in directory.rglob('*'):
                if path.is_file() and re.match(r'^(licen[sc]e|copying|copyright|notice|ofl|unlicense|authors)(?:[._-]|$)', path.name, re.I):
                    copy(path, stage / 'licenses' / crate / path.relative_to(directory))
            if package.get('license_file'):
                path = directory / package['license_file']
                copy(path, stage / 'licenses' / crate / path.name)
        (stage / 'licenses/THIRD-PARTY.md').write_text('\n'.join(inventory) + '\n')
        (stage / 'RELEASE.txt').write_text(
            f'Omabib {version}\nPlatform: {PLATFORMS[args.platform]}\n'
            f'Source commit: {run("git", "rev-parse", "HEAD").strip()}\n'
            'Install: ./scripts/install.sh\n'
            'No Rust toolchain or compilation is needed to install this archive.\n')
        destination = output / f'{name}.tar.gz'
        archive(stage, destination)
        artifacts.append(destination)
        if args.source:
            source = Path(temporary) / f'omabib-{version}-source'
            source.mkdir()
            source_tar = Path(temporary) / 'source.tar'
            subprocess.run(['git', 'archive', '--format=tar', '-o', str(source_tar), 'HEAD'], cwd=ROOT, check=True)
            with tarfile.open(source_tar) as tar:
                tar.extractall(source, filter='data')
            # The source asset contains native sources and license files inside the crates too.
            config = run('cargo', 'vendor', '--locked', '--versioned-dirs', 'vendor', cwd=source)
            (source / '.cargo').mkdir(exist_ok=True)
            with (source / '.cargo/config.toml').open('a') as stream:
                stream.write('\n' + config)
            destination = output / f'{source.name}.tar.gz'
            archive(source, destination)
            artifacts.append(destination)
    checksum_lines = []
    for path in artifacts:
        with path.open('rb') as stream:
            checksum_lines.append(f'{hashlib.file_digest(stream, "sha256").hexdigest()}  {path.name}\n')
    checksums = ''.join(checksum_lines)
    (output / 'SHA256SUMS').write_text(checksums)
    print(checksums, end='')


if __name__ == '__main__':
    main()
