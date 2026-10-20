# Developing Omabib

Omabib has two parts: `omabib`, a Rust program that is the command line, the library service (`omabib serve`) and the MCP server (`omabib mcp`); and `omabib-desktop`, a Qt 6 app that shows the window (see [desktop/README.md](../desktop/README.md)). The app starts the service when nothing answers on its socket.

## Build from source

You need Rust 1.92 or newer (Typst requires it), clang, a C/C++ toolchain with `make`, Git, and, for the app, CMake and Qt 6.5 or newer with Quick, Quick Controls and Network. The first build compiles MuPDF and Typst and takes several minutes.

On Linux, with a recent enough Qt from your distribution (Arch and Fedora have one; Ubuntu and Debian don't yet, so use the [Qt installer](https://www.qt.io/download-qt-installer-oss) or [aqtinstall](https://github.com/miurahr/aqtinstall)):

```bash
git clone https://github.com/atomashevic/omabib.git
cd omabib
./scripts/build.sh
cmake -S desktop -B build/desktop -DCMAKE_BUILD_TYPE=Release
cmake --build build/desktop -j
./scripts/install.sh
```

`scripts/install.sh` installs `target/release/omabib` (or `$CARGO_TARGET_DIR/release/omabib`, or a path you give it) and `build/desktop/omabib-desktop` against the system's Qt. To update, keep any local changes, then `git pull --ff-only` and run the same steps again.

To build what a release ships, with Qt bundled (on a Mac, the only way to install from source), do what the [release workflow](../.github/workflows/release.yml) does. `QT` is the Qt you built with, such as `~/Qt/6.10.3/macos`. `--version` is `v` plus the semver shared by `Cargo.toml`, `manifest.json` and `desktop/CMakeLists.txt`. On this tree that is `v0.1.1`, and `omabib --version` must print `omabib 0.1.1`. `scripts/package-release.py` refuses any other value:

```bash
cargo build --release --locked
cmake -S desktop -B build/desktop -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT"
cmake --build build/desktop -j
# macOS:
scripts/bundle-macos-app build/desktop/omabib-desktop.app target/release/omabib "$QT" target/app
python3 scripts/package-release.py --version v0.1.1 --platform macos-arm64 --app target/app
# Linux:
scripts/bundle-linux-app build/desktop/omabib-desktop "$QT" target/app
python3 scripts/package-release.py --version v0.1.1 --app target/app
# Then install the archive the way users do:
OMABIB_DOWNLOAD_URL="file://$PWD/target/dist" OMABIB_VERSION=v0.1.1 sh scripts/get.sh
```

Packaging needs Python 3.12 or newer and network access for uncached crates. `--source` (from a clean checkout) also writes the source archive with vendored dependencies, which builds offline with `./scripts/build.sh --offline`.

If the build fails, check `rustc --version`, `cargo --version`, `clang --version` and `make --version`.

## Working on the window

The UI is QML in `plugin/`, compiled into `omabib-desktop`. To try changes without rebuilding, point the app at the folder:

```bash
OMABIB_UI_DIR=$PWD/plugin build/desktop/omabib-desktop
```

`build/desktop/omabib-desktop --help` lists the app's own options (`--toggle`, `--add`, `--query`, `--pdf`, `ipc`, `screenshot`, `--quit`). After editing the page-color shader (`plugin/components/shaders/pagecolors.frag`), rebuild its `.qsb` with `scripts/build-shaders` (needs Qt Shader Tools). The icon font is cut to the icons `Icons.js` names; `scripts/subset-icons` recuts it.

## The Omarchy shell plugin

Omabib began as a plugin for the [Omarchy](https://omarchy.org) shell, and the repository still carries it: `manifest.json`, `plugin/Entry.qml` and `scripts/omabib-plugin`. When the installer finds Omarchy, it also installs the plugin and the `omabib.service` user service. The plugin's bar icon and its shortcuts then hand off to the standalone app.

- A plugin added with `omarchy plugin add` is managed by Omarchy. Install a locally built backend beside it with `./scripts/install.sh --backend-only`, which leaves the Git checkout alone.
- After installing plugin QML, run `omarchy-restart-shell`; a rescan keeps the old compiled code.
- If the installer reports an unmanaged plugin, it found a plugin folder without the `.omabib-managed` marker. Inspect and move it aside before installing again.
- The service: `systemctl --user status omabib.service` and `journalctl --user -u omabib.service -n 50 --no-pager`.
- To remove the plugin and its service: `python3 ~/.config/omarchy/plugins/io.github.atomashevic.omabib/scripts/omabib-plugin remove-backend`, then `omarchy plugin remove io.github.atomashevic.omabib`.

## Tests

```bash
cargo test --locked
cargo clippy --all-targets -- -D warnings
python scripts/test_transport.py target/release/omabib
python3 scripts/test_plugin_entry.py
python3 scripts/test_plugin_lifecycle.py
python3 scripts/test_plugin_backend.py target/dist/omabib-0.1.1-linux-x86_64.tar.gz
python scripts/benchmark.py --directory /absolute/scratch/benchmark --binary target/release/omabib
scripts/test-get target/dist screenshot.png
```

The UI components render offscreen without a desktop: `QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl /usr/lib/qt6/bin/qmltestrunner -import tests/qml/imports -input tests/qml` loads them against a stub `qs.Commons` module and a stand-in for `App.qml`, and saves screenshots of every tab to `/tmp/omabib-qml-shots` (create it first). The check of theme page colors needs the OpenGL backend; with `QT_QUICK_BACKEND=software` Qt skips shaders, and that check is skipped with a warning.

- `node scripts/test_overview_text.js [overview.md]` tests the AI summary's Markdown renderer, `node scripts/test_markdown.js` the note features, and `node scripts/test_chat_text.js` the chat's tool labels, approval text and page links. `python3 scripts/test_icons.py` checks that every icon `Icons.js` names is in the icon font.
- `scripts/test-get` installs a release folder with `get.sh` into the current home, starts the service, opens the app and saves a screenshot. CI runs it in fresh containers and on macOS; don't run it in your own home.
- `scripts/test_metadata.py target/release/omabib` makes live requests to Crossref, DataCite, OpenAlex, Semantic Scholar, Europe PMC and arXiv against a temporary library. Run it only when checking those services, since a busy run can hit Crossref's rate limit.
- `scripts/test_claude.py target/release/omabib` checks the Claude Code and Claude Desktop hand-offs and the settings helper against a temporary library and config folder.
- `scripts/test_chat_agents.py target/release/omabib` chats with the real Claude Code and Codex through an isolated service (a read, then a write that must wait for approval), using a few messages of each subscription. `scripts/record_chat_fixtures.py target/release/omabib` re-records the event streams the chat tests replay (`tests/fixtures/chat/`, scrubbed of personal details) after a CLI update.
- `scripts/test_ui.py` and `scripts/test_tabs_ui.py` are opt-in live keyboard tests against an isolated socket. They type into the desktop, so run them while no one else is typing.

The benchmark refuses to overwrite a database and uses synthetic metadata, so it says nothing about real-world relevance. See [VERIFICATION.md](../VERIFICATION.md) for measured results and limits.

## Releases

Bump one semver in four places and merge that commit to `main`. The four places are `Cargo.toml` (`package.version`), `Cargo.lock` (the `omabib` package), `manifest.json` (`version`) and `desktop/CMakeLists.txt` (`project(omabib-desktop VERSION …)`). This tree is `0.1.1`. Tag the merged commit `vX.Y.Z`, `v` plus the same semver, and push the tag. GitHub Actions publishes the artifacts.

The [release workflow](../.github/workflows/release.yml) runs on a `v*` tag and when **Release** is started by hand. A tag push is what publishes. A manual Release run is a rehearsal: it builds and keeps the archives and a screenshot of the app on each system, and does not publish.

On a tag, `linux`, `linux-install` and `macos` have to succeed before `publish`. `linux` (Ubuntu 22.04, glibc 2.35) checks that the tag is `v` plus the Cargo version and that `manifest.json` and `desktop/CMakeLists.txt` match, shellchecks the install scripts, builds, tests, bundles Qt `6.10.*`, packs the archive and the vendored source, and installs that archive on the runner. `linux-install` runs `scripts/test-get` on Ubuntu 22.04, Ubuntu 24.04, Debian 12, Fedora 42 and Arch. `macos` (macOS 15, deployment target 13.0, Apple silicon) packs `Omabib.app`, installs it with `get.sh`, then runs the tests. `publish` writes `SHA256SUMS`, copies `scripts/get.sh` with this tag filled in, and creates the GitHub release. A tag that contains `-` is a prerelease.

Leave a published tag in place. `v0.1.1` is published. Move a tag only when the `linux` job fails before `publish`: fix the tree on a new commit and point the tag at that commit. After `publish`, the next fix is a new version.

After a release is published, [Install test](../.github/workflows/install-test.yml) curls that release's `get.sh` and pipes it to `sh`, which is the README command with the published tag in place of `latest`. It runs on clean macOS 15 and macOS 26. A manual run with an empty tag uses the README command as written (`curl -fsSL https://github.com/atomashevic/omabib/releases/latest/download/get.sh | sh`) and installs the latest release. A manual run with a tag uses that release's `get.sh`. Each run keeps a throwaway home, checks the command, the service and the MCP server, and opens the app. It does not use a real library, a cloud account or a Google Drive folder. A macOS 15 Intel runner checks that `get.sh` refuses Intel Macs and installs nothing. macOS 14 is not included: that runner image retires on 2026-11-02.

The Google and Dropbox sign-in apps' secrets are built in from the repository's Actions secrets `OMABIB_GOOGLE_CLIENT_SECRET` and `OMABIB_DROPBOX_APP_SECRET`. A build without them can't connect those two; for a local build, export the same variables before `cargo build`, or keep the downloaded credentials beside Omabib's `rclone.conf` (`google-client.json`, `dropbox-client.json`).

Each release has:

- `omabib-VERSION-linux-x86_64.tar.gz`: the binary, the app with its Qt, the helpers, the shell plugin and service, the agent skill and license texts.
- `omabib-VERSION-macos-arm64.tar.gz`: `Omabib.app`, holding the app, the binary and helpers, with its Qt; the agent skill and license texts.
- `omabib-VERSION-source.tar.gz`: the tagged source with vendored Cargo dependencies, native sources included.
- `SHA256SUMS`: checksums for the archives.
- `get.sh`: the install script, set to install this release.

To install an archive by hand, download it with `SHA256SUMS` into one folder, check it with `sha256sum --check --ignore-missing SHA256SUMS` (on a Mac, compare `shasum -a 256 FILE` with its line in `SHA256SUMS`), extract it and run `./scripts/install.sh` inside. `get.sh` does exactly that; `OMABIB_VERSION=v0.1.1` before `sh` picks a release.

The macOS app is signed ad hoc, not notarized. Installing with `curl` adds no quarantine flag, so it opens normally; a copy downloaded in a browser needs `xattr -dr com.apple.quarantine ~/Applications/Omabib.app`.

V1 leaves out automatic merging of duplicate references, embeddings, full-text PDF search and annotation.
