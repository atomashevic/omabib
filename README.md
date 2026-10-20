<p align="center">
  <a href="https://omabib.github.io"><img src="https://omabib.github.io/favicon.svg" width="84" height="84" alt="Omabib"></a>
</p>

<h1 align="center">Omabib</h1>

<p align="center"><b>The reference manager you share with your agent</b></p>

<p align="center">
  <a href="https://omabib.github.io">Website</a> ·
  <a href="#install">Install</a> ·
  <a href="docs/guide.md">User guide</a> ·
  <a href="https://omabib.github.io/privacy.html">Privacy</a> ·
  <a href="https://github.com/sponsors/atomashevic">Sponsor</a>
</p>

<p align="center">
  <a href="https://github.com/atomashevic/omabib/releases/latest"><img src="https://img.shields.io/github/v/release/atomashevic/omabib?label=release&color=0969da" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/Linux%20%C2%B7%20macOS-0969da" alt="Linux and macOS">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-0969da" alt="AGPL-3.0"></a>
</p>

Omabib is a fast reference manager and PDF reader for Linux and macOS. Read, annotate and organize your literature with your own agent working alongside you: it reads the paper you have open, answers with page references, and saves notes when you ask. A fast MCP server is built in, so Claude Code, Codex or any other MCP client can use your library too.

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/library-dark.webp"><img src="https://omabib.github.io/img/library-light.webp" alt="Omabib's library: projects in the sidebar, a list of papers, and Attention Is All You Need open with its abstract, citation key and a note."></picture>

## Install

Open a terminal and paste:

```bash
curl -fsSL https://github.com/atomashevic/omabib/releases/latest/download/get.sh | sh
```

Then open **Omabib** from your applications (Spotlight or Launchpad on a Mac), or run `omabib open`.

- **Runs on** Linux on x86-64 (Ubuntu 22.04 or newer, Debian 12, Fedora, Arch and most others) and macOS 13 or newer on Apple silicon.
- **No admin password or developer tools.** Everything goes into your home folder, checked against the release's checksums first ([the script](scripts/get.sh)).
- **A normal desktop already has the libraries.** On a minimal Linux system the installer stops and prints two package lists: fontconfig and freetype for the `omabib` command, and OpenGL, X11 and xcb for the window. It uses apt, dnf or pacman, and it copies nothing until those packages are installed.
- **To update,** run the same command again. Your library and settings stay as they are.

On a Mac, the first time you open Settings or a chat, macOS may offer to install its command line tools, which include Python. Accept, and you're set.

## What it does

<table>
<tr>
<td width="50%" valign="top">

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/features/search-dark.webp"><img src="https://omabib.github.io/img/features/search-light.webp" alt="Searching a project for attention"></picture>

**Fast search as you type** &nbsp;<kbd>Ctrl</kbd>+<kbd>F</kbd><br>
Titles, authors, citation keys, abstracts and your notes. Results follow every keystroke, even in a large library, and small typos are forgiven.

</td>
<td width="50%" valign="top">

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/features/ask-dark.webp"><img src="https://omabib.github.io/img/features/ask-light.webp" alt="A chat asking before it saves a note"></picture>

**Bring your own agent** &nbsp;<kbd>c</kbd><br>
Claude Code or Codex, on your own login, with no API keys. It reads the paper, your notes and the PDF, cites pages you can click, and asks before it changes anything.

</td>
</tr>
<tr>
<td width="50%" valign="top">

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/features/agents-dark.webp"><img src="https://omabib.github.io/img/features/agents-light.webp" alt="Agents found on this computer"></picture>

**First-class MCP, built in**<br>
One fast server for Claude Code, Codex, Claude Desktop and any MCP client. Agents search your library, fetch many papers in one call, read notes and clips, and open PDFs.

</td>
<td width="50%" valign="top">

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/features/read-dark.webp"><img src="https://omabib.github.io/img/features/read-light.webp" alt="A paper open in a reader tab"></picture>

**Read PDFs in tabs** &nbsp;<kbd>Enter</kbd><br>
Notes, abstract and AI summary beside the page, and your page remembered. Zoom with the wheel, find with <kbd>/</kbd>, and read in your theme’s colors at night.

</td>
</tr>
<tr>
<td width="50%" valign="top">

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/features/clip-dark.webp"><img src="https://omabib.github.io/img/features/clip-light.webp" alt="A clipped figure saved as a note"></picture>

**Clip a figure into a note** &nbsp;<kbd>r</kbd><br>
Drag over a figure, table or equation. It lands in a note with its page, sharp at any zoom, ready for you and your agent.

</td>
<td width="50%" valign="top">

<picture><source media="(prefers-color-scheme: dark)" srcset="https://omabib.github.io/img/features/sync-dark.webp"><img src="https://omabib.github.io/img/features/sync-light.webp" alt="A library found in Dropbox"></picture>

**Sync through your own storage**<br>
Google Drive, Dropbox, OneDrive or a folder you already sync. Edits merge, PDFs come along, and the files stay readable in your own storage.

</td>
</tr>
</table>

**Cite in a click.** **Cite** on any paper copies its citation key, a LaTeX `\cite{…}`, a Pandoc or Quarto `[@…]` citation, or the full BibTeX entry. **Copy project bibliography** in <kbd>Ctrl</kbd>+<kbd>K</kbd> copies a whole project's BibTeX.

## Get started

1. **Add a paper.** Click **Add** and paste a DOI, an arXiv ID, a link to the paper, or a BibTeX entry, or paste one straight into the search box and press <kbd>Enter</kbd>. Omabib fills in the details, finds the abstract, and downloads an open-access PDF when there is one.
2. **Bring your existing library.** Export a `.bib` file from Zotero, Mendeley or any other manager, then press <kbd>Ctrl</kbd>+<kbd>K</kbd> and choose **Import BibTeX file…**.
3. **Organize.** Click **New project** in the sidebar, then **Add to project** on any paper. Each project keeps its own notes.

### Your agent, alongside you

- Open a paper and click **Ask Claude** (or **Ask Codex**, chosen in **Settings**). Select a passage in the PDF and press <kbd>c</kbd> to ask about just that part.
- It uses your own [Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex) login: install one and sign in once. The rest of Omabib works without any AI account.
- To use your library from other agents too:
  - **Codex:** in **Settings**, click **Connect Codex**.
  - **Claude Desktop:** in **Settings**, click **Add Omabib to Claude Desktop**, then restart it.
  - **Claude Code:** run `claude mcp add --scope user omabib -- ~/.local/bin/omabib mcp`.

### Sync between your computers

Click **Sync** at the bottom of the sidebar and pick where to keep your library. Cloud storage works through [rclone](https://rclone.org), a free sync tool; if you don't have it, install it once with `brew install rclone` on a Mac, or `sudo apt install rclone`, `sudo dnf install rclone` or `sudo pacman -S rclone` on Linux.

## Everything is a keystroke away

And a button too, for the mouse. On a Mac, <kbd>⌘</kbd> takes the place of <kbd>Ctrl</kbd> and <kbd>⌥</kbd> of <kbd>Alt</kbd>.

| In the library | | In a PDF | |
|---|---|---|---|
| <kbd>Ctrl</kbd>+<kbd>K</kbd> | every action | <kbd>j</kbd> <kbd>k</kbd>, wheel | scroll |
| <kbd>Ctrl</kbd>+<kbd>F</kbd> | search | <kbd>Ctrl</kbd> + wheel, <kbd>+</kbd> <kbd>−</kbd> | zoom |
| <kbd>Enter</kbd> | open the PDF | <kbd>w</kbd> / <kbd>z</kbd> | fit width / page |
| <kbd>Tab</kbd> | paper details | middle-button drag | pan |
| <kbd>Ctrl</kbd>+<kbd>T</kbd> | open in a tab | <kbd>g</kbd><kbd>g</kbd> / <kbd>G</kbd> | first / last page |
| <kbd>Ctrl</kbd>+<kbd>P</kbd> | switch project | <kbd>/</kbd>, <kbd>n</kbd> <kbd>N</kbd> | find, next, previous |
| <kbd>Ctrl</kbd>+<kbd>1</kbd>…<kbd>6</kbd> | detail sections | <kbd>r</kbd> | clip into a note |
| <kbd>Alt</kbd>+<kbd>1</kbd>…<kbd>9</kbd> | switch tabs | <kbd>a</kbd> | note on this page |
| <kbd>Ctrl</kbd>+<kbd>W</kbd> | close the tab | <kbd>c</kbd> | ask about the selection |
| <kbd>Esc</kbd> | back, or hide | <kbd>Ctrl</kbd>+<kbd>R</kbd> | theme or original colors |

Closing the window keeps Omabib ready in the background, so it opens instantly. To show or hide it from anywhere, add a shortcut for `omabib open` in your desktop's keyboard settings; `omabib add` opens straight into the add box.

## Your library stays yours

Omabib runs on your computer and keeps your library there. Sync goes straight to storage you already have. See the [privacy policy](https://omabib.github.io/privacy.html).

- **Free and open source:** AGPL, no subscription.
- **No servers, no analytics:** nothing to sign up for, nothing tracked.
- **Your files:** the library and the PDFs Omabib downloads live in `~/.local/share/omabib/`. PDFs you attach from elsewhere stay where they are.
- **No lock-in:** BibTeX in and out, and `omabib backup ~/omabib-backup.db` makes a backup any time.

## Uninstall

This removes the app and keeps your library. Delete `~/.local/share/omabib` too if you want it gone.

**Linux:**

```bash
omabib-desktop --quit; pkill -f 'omabib serve'
rm -rf ~/.local/lib/omabib ~/.local/share/applications/omabib.desktop
rm -f ~/.local/share/icons/hicolor/*/apps/omabib.{png,svg}
rm -f ~/.local/bin/omabib ~/.local/bin/omabib-*
```

**macOS:**

```bash
omabib-desktop --quit; pkill -f 'omabib serve'
rm -rf ~/Applications/Omabib.app
rm -f ~/.local/bin/omabib ~/.local/bin/omabib-*
```

## Troubleshooting

- **`omabib: command not found`.** Open a new terminal. If that doesn't help, add `~/.local/bin` to your `PATH`: put `export PATH="$HOME/.local/bin:$PATH"` at the end of `~/.profile` (on a Mac, `~/.zprofile`).
- **The installer says `python3` is missing.** Omabib's helpers use Python 3, which most Linux desktops include. Install it (`sudo pacman -S python`, `sudo apt install python3` or `sudo dnf install python3`) and run the install command again.
- **The installer lists missing Linux libraries.** It prints one command for the `omabib` program (fontconfig and freetype) and another for the window (OpenGL, X11 and xcb), for apt, dnf or pacman, then exits. Nothing is installed. Install those packages and run the command again.
- **The app doesn't open on Linux.** Run `omabib-desktop` in a terminal to see why.
- **macOS says Omabib can't be opened.** That happens only to a copy downloaded with a web browser. Run `xattr -dr com.apple.quarantine ~/Applications/Omabib.app`, or install with the command above instead.
- **Chat can't find Claude Code or Codex.** Install it, run `claude` or `codex` once in a terminal to sign in, then choose it in **Settings**.
- **Something else?** [Open an issue](https://github.com/atomashevic/omabib/issues) with what happened and the output of `omabib --version` and `uname -sm`.

## Learn more

- **[User guide](docs/guide.md):** every feature in detail: tabs, the PDF reader, notes, chat, sync, metadata, search and the command line.
- **[Agent guide](skills/omabib/SKILL.md)** and **[API](API.md):** what agents can do with your library, and the JSON operations behind it.
- **[Development](docs/development.md):** building from source, tests and releases.

## License

Omabib is free software under the [GNU Affero General Public License v3.0 or later](LICENSE), Copyright (c) 2026 Omabib contributors. It uses [MuPDF](https://mupdf.com/) (AGPL-3.0) to render PDFs, and [Typst](https://github.com/typst/typst) with the embedded [mitex](https://github.com/mitex-rs/mitex) scope in `src/mitex/` (Apache-2.0) to render math.
