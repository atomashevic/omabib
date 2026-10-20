# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Sync treats a reference's BibTeX entry as one fact. When two computers edited the same reference before syncing, the columns were merged one by one while the entry text came from whichever edit was later, so the library could show one title and the export another. Now the later entry wins whole, and the title, authors, year, DOI and other fields are read back out of it on every computer. The entry text is copied as written, so protected braces and corporate authors survive a sync. Nothing about the sync format changes.

## [0.1.1] - 2026-10-20

### Changed

- The icon is citation brackets around a point, in the sidebar and rail, the Linux launcher icons (PNG sizes 16 through 512, plus the SVG), and the macOS app icon. `scripts/render-icons` draws them, with heavier strokes at the small sizes. The Linux package includes every size. On Linux the window sets that icon for X11 taskbars; macOS keeps the bundle icon. Uninstall removes the sized PNGs as well as the SVG.
- The README uses the website's logo, headline, and description, the app screenshot and six feature cards in light and dark, and shortcuts shown as keycaps.

### Fixed

- `scripts/install.sh` installs the launcher icons without calling `basename`. The release install test runs with only the commands a bare system is sure to have, and `basename` is not one of them. Bash expansion finds the size folder (such as `48x48`) instead.

## [0.1.0] - 2026-10-20

### Added

- Omabib, a reference manager and PDF reader for Linux on x86-64 (Ubuntu 22.04 or newer, Debian 12, Fedora, Arch, and most others) and macOS 13 or newer on Apple silicon. One command installs it into the home folder after checking the release checksums. No admin password and no developer tools.
- Add a paper from a DOI, an arXiv id, a link, or BibTeX, including by pasting one into the search box. Import a `.bib` file. Omabib fills in the details, finds the abstract, and downloads an open-access PDF when there is one.
- Search titles, authors, citation keys, abstracts, and notes as you type. Small typos are forgiven.
- Read PDFs in tabs, with notes, the abstract, and an AI summary beside the page, and the page remembered. Zoom, pan, find, and a theme-colored page for reading at night.
- Markdown notes with a live preview and math. Clip a figure, table, or equation into a note with its page. Projects keep their own notes.
- Copy a citation key, a LaTeX `\cite`, a Pandoc or Quarto citation, or the BibTeX entry, and copy a whole project's bibliography.
- Ask Claude Code or Codex about the open paper, or about a selected passage. The agent uses your own login, cites pages you can open, and asks before it changes the library. The rest of the app works without an AI account.
- A built-in MCP server for Codex, Claude Desktop, and Claude Code. Settings can connect Codex and add Omabib to Claude Desktop; on macOS that config is `~/Library/Application Support/Claude`.
- Sync through rclone to Google Drive, Dropbox, OneDrive, or a folder you already sync. Google Drive signs in as Omabib's own app and only sees My Drive → Omabib. Dropbox signs in through Omabib's App Folder and only sees Dropbox → Apps → Omabib.
- The library stays on the computer, in `~/.local/share/omabib/`. BibTeX goes in and out, and `omabib backup` writes a backup. Free software, AGPL-3.0-or-later.

[Unreleased]: https://github.com/atomashevic/omabib/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/atomashevic/omabib/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/atomashevic/omabib/releases/tag/v0.1.0
