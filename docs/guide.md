# Omabib user guide

Everything Omabib does, in detail. New to Omabib? Start with the [README](../README.md), which covers installing and the first steps.

On a Mac, press **⌘** wherever this guide says **Ctrl**, and **⌥** for **Alt**.

- [The window](#the-window)
- [Tabs](#tabs)
- [The command palette](#the-command-palette)
- [Getting started](#getting-started)
- [Adding references](#adding-references)
- [Moving from Zotero](#moving-from-zotero)
- [Importing BibTeX](#importing-bibtex)
- [Reading PDFs](#reading-pdfs)
- [Notes](#notes)
- [Clipping figures, tables and equations](#clipping-figures-tables-and-equations)
- [Chat](#chat)
- [Connecting other agents](#connecting-other-agents)
- [Settings](#settings)
- [Sync](#sync)
- [PDF files](#pdf-files)
- [Metadata and abstracts](#metadata-and-abstracts)
- [Deleting](#deleting)
- [Search](#search)
- [Your data, backups and restoring](#your-data-backups-and-restoring)
- [The command line](#the-command-line)
- [Projects, notes and agent access](#projects-notes-and-agent-access)

## The window

The window has three parts.

- **The sidebar** on the left. Under **Library**, **All references** shows everything and **Needs attention** narrows the list to references missing an abstract or a PDF, or to sync changes waiting for your review. **Open** lists your open tabs, and **Projects** your projects, with **New project** below them. At the bottom are **Sync**, with its status ("Synced 2 min ago", "Changes waiting to sync"…) and a button to sync now, and **Settings**.
- **The list** in the middle, under the search field, **Add** and the actions button. Each result shows its title, authors and year, with badges for a PDF, notes, an AI summary, a missing abstract, or an open tab. The filter button narrows it by author, year, type and label. With an empty search field the newest additions come first; **Ctrl+S** switches between date-added and citation-key order.
- **The details** of the selected paper on the right, opened with **Tab** or a click. Its toolbar has **Open PDF**, **Cite**, **Ask Claude** (or **Ask Codex**), **Add to project** and **⋯** for everything else: open the link, a new note, open in a tab, fill in metadata, edit the BibTeX, attach a PDF, copy it in various formats, open the PDF in another app, and delete. Below are its sections: **Overview** (abstract and details), **AI summary** (arXiv papers), **Notes**, **Files**, **BibTeX** and **Chat**. **Ctrl+1**–**Ctrl+6** pick a section and **Ctrl+Tab** cycles through them.

The abstract and the AI summary are selectable: drag across paragraphs and press **Ctrl+C**, or use their **Copy** buttons (the AI summary's copies Markdown).

**Esc** hides the window, and so does **q** while the search field is empty. Closing the window keeps Omabib running in the background so it opens instantly; `omabib-desktop --quit` stops it. On Omarchy, **Super+Alt+B** shows or hides the window.

## Tabs

The strip above the list starts with the **library tab**: the current project (or All references), its reference count, and a chevron for the project picker. Papers open in **paper tabs** beside it, each showing that paper's details at full width, and PDFs open in **reader tabs**.

- **Open:** double-click a result, press **Ctrl+T** or **Ctrl+Enter** in the search field, or choose **Open in a tab** in **⋯**. Middle-click a result to open it in the background. A paper that's already open switches to its tab.
- **Switch:** click a tab or its entry in the sidebar, press **Ctrl+PgUp**/**Ctrl+PgDn** to cycle, **Alt+0** for the library tab and **Alt+1**–**Alt+9** for the others. **Ctrl+F**, or simply typing while a paper tab is showing, takes you back to the search. In a paper tab, **Esc** goes back to the library as you left it.
- **Close:** tabs stay open until you close them, including after you hide the window or restart the computer. Close one with its ×, a middle-click or **Ctrl+W**. Deleting a reference closes its tabs.
- **Limits:** up to 12 paper and reader tabs together. Tabs shrink as the strip fills, then overlap with the active tab on top.

Each paper tab remembers its section, and each reader tab its page and zoom. Tabs are saved in `~/.local/state/omabib/tabs.json`, which holds only reference IDs, citation keys, titles, sections, pages and zoom levels.

## The command palette

**Ctrl+K**, or the actions button beside **Add**, lists every action. Type to filter it, or type an action's number to run it. For a first digit that could start a two-digit number (1 or 2), press **Enter** straight away or wait a moment for the second digit.

## Getting started

A new, empty library opens on a welcome page with the ways to fill it:

- **Move your Zotero library.** When Zotero is on this computer, Omabib says what it found ("1,962 references and 1,470 PDFs") and **Import from Zotero…** brings it over. Otherwise **Find Zotero library…** lets you choose Zotero's `zotero.sqlite`. See [Moving from Zotero](#moving-from-zotero).
- **Import a BibTeX file** exported from Mendeley, EndNote, JabRef, Paperpile or any other manager. See [Importing BibTeX](#importing-bibtex).
- **Add a paper** by DOI, arXiv ID or link, or a PDF you have. See [Adding references](#adding-references).
- **Set up sync** when your library already lives on another computer. See [Sync](#sync).

The page stays until the first reference arrives. All four are also in **Ctrl+K**, and the imports in **Settings**.

## Adding references

Click **Add** (or **1 · Add new item** in the palette, or run `omabib add`) and paste any of:

- a DOI, like `10.1145/3025453.3025717`
- an arXiv ID, like `arXiv:1706.03762`
- a link to the paper's page
- a BibTeX entry
- several identifiers at once, separated by spaces or commas

You can also paste an identifier into the search field and press **Enter** when nothing matches.

Omabib looks up the title, authors and year, finds an abstract when it can, and looks for an open-access PDF. It previews each item with the citation key it would get (`family_word_year`, like `watts_collective_1998`) and saves nothing until you press **Import**. Adding a single identifier also downloads and attaches its PDF. A paper that's already in your library is filled in rather than added twice. Afterwards, the new paper (or the first of several) is selected.

### A PDF you already have

Click **Add PDF** beside **Add**, drop PDFs on the window, choose **Import PDF…** in **Ctrl+K**, or click **Choose PDF…** in the add box. Omabib reads the first five pages of each PDF and identifies the paper the way Zotero does, in this order:

1. an arXiv ID stamped on the first page, a DOI in the file's properties, or a DOI printed on the first two pages;
2. an ISBN printed in it, looked up on [Open Library](https://openlibrary.org);
3. its title (the largest text above the abstract) searched on Crossref, then Semantic Scholar, arXiv and Europe PMC.

A record counts only when the PDF prints its title, and for a title under 50 letters also the surname of one of its first two authors. A DOI or a title the paper cites is therefore not taken for the paper itself. Omabib stops at the first record that passes. When none passes, or two records tie, the preview lists the records it found and marks them **check that it's this paper**. The last entry in the list is made from the PDF itself: its title, the authors in its file properties, and its abstract.

**Add to library** copies the PDF to `~/.local/share/omabib/pdfs/<citekey>.pdf` and attaches it. The original file stays where it was. If the same file is already in your library, the preview says so. Several dropped PDFs are previewed one after another.

Only the title, one surname and the identifiers are sent to these services; the PDF itself is not uploaded. A scanned PDF without a text layer can't be read: add it by DOI, or with the entry made from its file name.

For an arXiv paper, the **AI summary** section checks [alphaXiv](https://www.alphaxiv.org) for a published overview the first time you open it, keeps a copy, and lays it out for reading, with a strip that jumps between sections. When there's no overview yet, it says so and links to the paper on alphaXiv.

From a terminal:

```bash
omabib add 10.1145/3025453.3025717                    # by DOI
omabib add arXiv:1706.03762 --project PROJECT_ID       # by arXiv ID, into a project
omabib add https://example.org/paper                   # by the paper's page
omabib add --pdf /absolute/path/to/paper.pdf            # recognized from the PDF itself
omabib add --dry-run 10.1145/x 10.1145/y                # preview several, save nothing
```

`omabib add` with nothing after it opens the add box in the window. `--no-pdf` skips the PDF download. `--pdf` identifies the PDF as above and adds it only when the match is sure, or with the entry made from the PDF when nothing was found online; `--pdf FILE --dry-run` lists the candidates and saves nothing.

## Moving from Zotero

**Import from Zotero…** (on the welcome page, in **Settings**, or in **Ctrl+K**) reads Zotero's own library and brings over:

- **Every reference**, under the citation key it has in Zotero (Zotero 7's own key, Better BibTeX's, or a `Citation Key:` line in Extra), so LaTeX and Pandoc documents that cite it keep working. A reference without a key gets one like `watts_collective_1998`. Zotero's fields become BibTeX fields, its tags become `keywords` (tags added automatically from databases are left out), and other lines in Extra are kept in `annotation`.
- **PDFs.** **Copy into Omabib** (the default) puts a copy in `~/.local/share/omabib/pdfs/`, so the library no longer depends on Zotero and sync can carry the files. **Use Zotero's files where they are** takes no extra space but needs the Zotero folder to stay.
- **Notes**, converted to Markdown. A note longer than Omabib's 64 KiB limit is split into parts.
- **Highlights and comments** made in Zotero's PDF reader, gathered into one note per PDF: each passage quoted with its page, then its comment.
- **Collections as projects.** A subcollection becomes a project named "Parent / Child". A group library's collections are named after the group, and a group library's other references go into a project named after it.

The dialog shows what it found before anything happens, and each part can be left out. Imported notes show "zotero" beside their date. Nothing in Zotero is changed: Omabib reads a copy of its database, so Zotero can stay open, although changes made in Zotero after that won't come over. Items in Zotero's trash stay behind, and a PDF without a parent item becomes a reference titled after its file, to fill in with **Fill metadata online**.

Importing again later brings over what's new. Omabib remembers what each Zotero item became, so nothing is added or copied twice, and a reference you deleted in Omabib since stays deleted. A paper already in Omabib from elsewhere (the same DOI, or the same citation key and title) is filled in rather than added twice. A PDF Zotero hasn't downloaded to this computer (with **Download files as needed** in Zotero's sync settings) can't come over; open it in Zotero, then import again. Web snapshots, EPUBs and standalone notes stay in Zotero.

From a terminal:

```bash
omabib zotero --dry-run                 # what would come over, from the library Omabib finds
omabib zotero                           # import it
omabib zotero --dir ~/Zotero --link-pdfs --no-groups
```

`--no-notes` and `--no-projects` leave notes and projects out.

## Importing BibTeX

Press **Ctrl+K** and choose **7 · Import BibTeX file…** to browse to a `.bib` file, or type its path (**Ctrl+L** focuses the path, **Alt+↑** goes up a folder). **6 · Paste BibTeX** imports pasted text. From a terminal:

```bash
omabib import /absolute/path/to/references.bib
```

Entries repeated within a file are merged: missing fields are combined and, where they disagree, the first value wins and the conflict is reported. Entries with different DOIs stay separate. The importer also repairs small slips, such as a missing comma between fields, a repeated field or a byte-order mark at the start. It keeps each entry's original text and never touches existing notes. A file it can't read unambiguously, with an unclosed brace or an undefined macro, is reported rather than half-imported.

## Reading PDFs

**Open PDF** (**Enter** on a result with a PDF, **Ctrl+O**, the toolbar's **Open PDF**, or `omabib pdf open CITATION_KEY`) opens the paper in a reader tab. If there's no PDF yet, Omabib looks for one first. Notes, the abstract and the AI summary sit in a pane to the right, and the reader keeps its page and zoom across restarts. Your PDF files are never changed.

| Keys | |
|---|---|
| Wheel, **j** / **k**, arrows | scroll |
| **Space** / **Shift+Space**, **PgDn** / **PgUp** | next / previous screen |
| Middle-button drag | pan |
| **Ctrl** + wheel, **+** / **−** | zoom |
| **0** or **w** / **z** | fit width / fit page |
| **gg** / **G**, a number and **G** | first page, last page, that page |
| **/**, then **n** / **N** | find, next / previous match |
| drag, double-click, **Ctrl+C** | select words, copy |
| **r** | clip a region into a note |
| **a** | note on the current page |
| **o** / **]** | contents / side pane |
| **c** | ask the chat about the selection, or open the chat |
| **Ctrl+R** | theme or original page colors |
| **Esc** | cancel the clip, selection or search; again to go back |
| **Ctrl+W** | close the tab |

Links inside the paper jump to their page, and web links open in your browser. **Open PDF in another app** in **⋯** hands the file to your system's PDF viewer.

### Theme colors

With **Theme colors** on (Settings → **PDF pages**, or **Ctrl+R**), reader tabs draw each page in the window's theme: the paper takes the theme's background and black ink its text color, so a dark theme reads as light text on a dark page. Colored ink keeps its hue, so links, highlighted terms and chart series stay recognizable. Photographs look like tinted negatives on a dark theme; switch back with **Ctrl+R** when a figure needs its real colors. Only the screen changes: the PDF, and the clips you save from it, keep the PDF's own colors.

## Notes

Notes are Markdown, previewed as you write. Every block shows rendered except the one you're editing, which shows its source; click a block, or move past its first or last line with **↑**/**↓**, to edit it. **Enter** continues a list, and a second **Enter** starts a new block. **Backspace** at the start of a block joins it to the one above. The toolbar inserts headings, emphasis, quotes, lists, code and math.

Math is written as `$…$` or `\(…\)` inline and `$$…$$` or `\[…\]` on its own line. `$5 and $10` stays text, and `\$` is a literal dollar sign. Fenced code blocks show their language.

Each note belongs either to a project or to the paper in general, and can carry labels and evidence (such as "p. 7"). Note cards have edit and delete buttons; deleting a note asks first and shows its project and opening words. It removes that note and its clip, and keeps the paper and its other notes.

## Clipping figures, tables and equations

In a reader tab, press **r** (or the crop button) and drag over a figure, table or equation. A note opens in the side pane with the clip, the region outlined on the page, the page as evidence and the current project as its scope. Add your comments and press **Ctrl+Enter**, or **Esc** to discard it. A click without dragging, or **a**, writes a plain note for that page instead. Saved clips stay outlined on the page: hover to see the note, click to edit it.

Clips are rendered from the PDF itself at 216 dpi, so they stay sharp at any zoom. They're stored with their notes in the library, included in backups, and synced as PNG files. Agents can read a clip's image through Omabib's tools, which helps with numbers, math and code.

## Chat

Omabib can chat with **Claude Code** or **Codex** about the paper you're looking at, right in the window: **Ask Claude** (or **Ask Codex**) on a paper, its **Chat** section (**Ctrl+6**), or the chat in a reader tab's side pane (**c**). Both run under your own login, so there are no API keys, and each message counts toward your Claude or ChatGPT plan. Install [Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex) and sign in once in a terminal; Omabib finds it.

- **What the agent sees:** the paper's details, abstract and BibTeX, all its notes with their projects, the clips and the PDF, plus Omabib's tools for your library. It cites pages as "p. N", and those open the page in the reader.
- **Asking about part of a paper:** select words in a reader tab and press **c** to attach them with their page, or clip a region with **r** and press **Ask chat**; the region goes along as an image.
- **Replies** stream in with the same Markdown and math as notes. **Stop** interrupts one.
- **The agent's steps** are hidden by default; while it works, the current step shows beside the typing dots. The steps button in the chat header lists them ("Read the reference", "Ran `ls`"), each expanding to its output.
- **Model and effort:** the model chip in the header picks the model and how hard it thinks. **Default** uses the agent's own configuration. A change applies from the next message and becomes the default for new chats with that agent.
- **Permissions:** reading is always allowed. Anything that changes your library (saving a note, adding or deleting a paper, attaching a PDF) waits for you to press **Allow once** or **Deny**; unanswered requests are denied after ten minutes. Claude Code also asks before running commands that change things, editing files or going online. Codex works in a read-only sandbox without network access.
- **Keeping answers:** **Copy** and **Save as note** sit under each answer. Saving opens the note editor with the answer, and the cited page as evidence.
- **History:** each paper keeps its chats. The history button lists them, starts a new one (with Claude Code or Codex) or deletes one. **Continue in a terminal** resumes the same session with `claude --resume` or `codex resume`.

Replies keep coming while the window is hidden. Up to three chats can work at once. Chats are stored in your library and its backups but don't sync between computers. Deleting a paper deletes its chats.

### Chatting from a terminal or a desktop app

On Linux, **⋯ → Chat in Codex CLI** (or Claude Code) opens the agent in a terminal with the same private snapshot of the paper and Omabib's tools, and **⋯ → Chat in ChatGPT** (or Claude Desktop) opens a prepared chat in the desktop app: ChatGPT gets an unsent draft in Codex mode, and Claude Desktop a new chat that reads the paper through Omabib's tools. Pick the agent and the app in **Settings**. These need `xdg-terminal-exec`, and the `chatgpt` and `claude-desktop` commands, so they aren't available on a Mac yet; the chat inside the window works everywhere.

## Connecting other agents

Omabib includes an [MCP](https://modelcontextprotocol.io) server, so any agent that speaks MCP can search your library, fetch several papers at once, read notes and clips, get a PDF's path, and save notes when you ask.

- **Codex:** **Settings → Connect Codex**, or `omabib-settings register-codex`. This registers Omabib's MCP server and installs the Omabib skill in `~/.codex/skills/omabib`. Reopen running Codex sessions afterwards. An existing connection to another library is left alone.
- **Claude Desktop:** **Settings → Add Omabib to Claude Desktop**, then restart Claude Desktop. This adds an `omabib` entry to Claude Desktop's config, keeps everything else, and saves the original once as `claude_desktop_config.json.omabib-backup`.
- **Claude Code:** `claude mcp add --scope user omabib -- ~/.local/bin/omabib mcp`
- **Anything else:** run `omabib mcp` as a stdio MCP server.

Omabib's own chats are connected already. If you used the old `omabib-mcp` companion, you no longer need it: **Connect Codex** reuses its connection and refreshes its skill, and you can delete its checkout. After updating Omabib, restart MCP clients so they see new tools. The [agent guide](../skills/omabib/SKILL.md) describes how agents should use the library.

## Settings

The **Settings** button at the bottom of the sidebar opens them. Changes apply immediately and are saved in `~/.config/omabib/settings.json`; `omabib-settings` prints or changes them from a terminal (`omabib-settings set ai_cli claude`).

- **Bring in your library:** **Import from Zotero…** and **Import BibTeX file…**.
- **Theme:** System (follows your desktop's light or dark setting), Light, Dark, or Omarchy. Omarchy appears when `~/.local/state/omarchy/current/theme/colors.toml` parses, and a new config chooses it. System, Light or Dark already written in `settings.json` stay as they are. An open window follows a theme change, including when Omarchy replaces the theme directory. `mode` `light` or `dark` in that file decides which; with no `mode`, the background does. A file that does not parse keeps the palette already on screen.
- **Reading font:** Mona Sans or Source Serif 4, for titles, abstracts and notes.
- **PDF pages:** **Original colors** or **Theme colors** (see [Theme colors](#theme-colors)).
- **Terminal chat:** Codex CLI or Claude Code, for chats and **Chat in…** in a terminal. **Connect Codex** is here too.
- **Desktop chat:** ChatGPT Desktop or Claude Desktop, with **Add Omabib to Claude Desktop**.

To change the PDF shortcut from **Ctrl+O**, set `OMABIB_PDF_SHORTCUT` in the environment Omabib starts in.

## Sync

Sync keeps your library the same on all your computers, through storage you already have. Open it from **Sync** in the sidebar, or **20** in the palette.

1. **Choose where:** Google Drive, Dropbox, OneDrive, a folder on this computer (kept in sync by Syncthing, Nextcloud or Dropbox's own app), or **Other**: any storage rclone reaches, such as S3, R2, B2 or WebDAV.
2. **Sign in:** cloud storage goes through [rclone](https://rclone.org). If it isn't installed, install it (`brew install rclone` on a Mac; `sudo apt install rclone`, `sudo dnf install rclone` or `sudo pacman -S rclone` on Linux) and the dialog continues by itself. Signing in needs rclone 1.56 or newer; Ubuntu 22.04 packages 1.53, so there install it from [rclone.org/install](https://rclone.org/install/) instead. Omabib opens the provider's sign-in page, and after you press **Allow** the dialog carries on. OneDrive's page names rclone, the tool Omabib uses to reach it.
3. **Start or join:** the first computer uploads its library. On the next one, Omabib shows what it found ("1,617 references, 13 notes, 17 PDFs, last synced from laptop 4 minutes ago"). An empty library joins with **Use it**. One that already has references offers **Merge**, which keeps everything from both, or **Replace this computer's library**. Either way, the local library is backed up first (the three newest backups are kept in `~/.local/share/omabib/backups/`).

From then on, sync runs by itself: about 30 seconds after you stop editing, every 5 minutes, when the window opens, and when you press **Sync**. Changes from other computers appear in the open window.

**What syncs:** references, notes and their clips, projects, attachments and cached AI summaries. Every PDF is uploaded; other computers download one the first time it's opened, or all at once with **Download all** in the Sync dialog. Chats, note history and each computer's own file paths stay where they are. Your storage gets a visible `Omabib/` folder with readable `pdfs/<citekey>.pdf` files, which you can open from a phone. The library file itself never leaves your computer.

**When edits meet:**

- **Different fields or papers:** everything merges. For the same field, the later edit wins on every computer.
- **A note edited on two computers:** the later edit wins everywhere. The other version is kept as a second note, and **Needs attention → Sync** offers **Keep both**, **Keep mine** or **Keep theirs**.
- **Deleted on one computer after you changed it on another:** the deletion wins, and your changes are kept for **Restore**.
- **The same paper added on two computers before they synced:** both stay, and Omabib points out the pair so you can delete one.
- **Two papers with the same citation key:** one gets a suffix.
- **Projects with the same name:** they become one.

**Stop syncing this computer** in the Sync dialog leaves its library as it is.

### Google Drive

Omabib signs in to Google Drive as its own app and asks only for the files it creates, in My Drive → Omabib. It can't see anything else in your Drive. To use your own Google OAuth client instead, save its downloaded JSON as `~/.config/omabib/google-client.json`, readable only by you (`chmod 600`); the `OMABIB_GOOGLE_CLIENT_ID` and `OMABIB_GOOGLE_CLIENT_SECRET` environment variables override the file.

### Sync from a terminal

```bash
omabib sync                                  # sync now; prints what was sent and received
omabib sync status
omabib sync connect dropbox|onedrive|drive   # opens the sign-in page and waits
omabib sync connect folder ~/Sync
omabib sync connect rclone REMOTE            # a remote in Omabib's rclone config
omabib sync start new|join|merge|replace
omabib sync disconnect
```

Omabib keeps its own rclone config in `~/.config/omabib/rclone.conf`, separate from yours.

## PDF files

**Attach PDF…** in **⋯** (or in the **Files** section) links a PDF you already have. **Open PDF** finds one itself: an attached file, a copy from your sync storage, or a freshly downloaded open-access copy (from the paper's own link, arXiv, OpenAlex or Semantic Scholar). **Open link** (**Ctrl+U**) opens the paper's web page or DOI instead, even when a PDF is attached. In **Files**, each attachment has **Open**, **Pull** when its file is missing, and **Remove link**; removing a link keeps the file.

PDFs Omabib downloads and PDFs you import go to `~/.local/share/omabib/pdfs/<citekey>.pdf`, so you can find them by name; an imported PDF is a copy. A PDF you attach to a paper already in the library stays where it is. Files can be up to 512 MiB.

```bash
omabib pdf add CITATION_KEY /absolute/path/paper.pdf
omabib pdf get CITATION_KEY [--no-download]     # print the path of a readable copy
omabib pdf open CITATION_KEY                     # open it in a reader tab
omabib pdf pull --attachment ATTACHMENT_UUID     # fetch it from your sync storage
omabib pdf pull --reference CITATION_KEY --url https://example.org/paper.pdf
omabib pdf remove ATTACHMENT_UUID
```

## Metadata and abstracts

**Fill metadata…** in **⋯** looks the paper up online: Crossref by DOI (or five candidates by title, authors and year), DataCite for repository DOIs such as arXiv's, then OpenAlex, Semantic Scholar and Europe PMC for a missing abstract. Review the match and choose **Fill missing fields** (**Ctrl+Enter**). Only empty fields are filled: your values, citation keys, attachments and notes stay as they are. None of these services needs an account. Nothing is looked up during normal searching, and no abstract is ever invented.

To fill in abstracts for papers that have a DOI or arXiv ID but no abstract yet:

```bash
omabib enrich --abstracts --dry-run --limit 20   # preview, writes nothing
omabib enrich --abstracts                        # the whole library, about one request a second
```

It reports progress as it goes and a summary at the end. Papers that already have an abstract are skipped, so it's safe to stop and run again.

## Deleting

**Delete…** in **⋯** shows the exact citation key and how many notes, attachments, project links and cached summaries go with it, and asks before deleting. PDF files stay on disk. With sync on, the deletion reaches your other computers.

## Search

Search covers titles, authors, citation keys, DOIs, abstracts and your notes. Exact citation keys and DOIs come first, then keyword, substring and typo matches. Misspellings of one letter are forgiven in words of four letters or more. Inside a project, note search covers that project's notes and general notes; **Also search other projects' notes** widens it.

To stay fast on every keystroke, a broad search shows the strongest matches rather than ranking every match, and the list says when adding a word would help. Search never reads the text inside PDFs. See [VERIFICATION.md](../VERIFICATION.md) for measurements.

## Your data, backups and restoring

| What | Where |
|---|---|
| Library | `~/.local/share/omabib/library.db` |
| PDFs Omabib downloads | `~/.local/share/omabib/pdfs/` |
| Settings and sync config | `~/.config/omabib/` |
| Open tabs | `~/.local/state/omabib/tabs.json` |
| Rendered pages (up to 500 MB) | `~/.cache/omabib/pages` |
| The app | `~/.local/lib/omabib/` on Linux, `~/Applications/Omabib.app` on a Mac |
| Commands | `~/.local/bin/` |

The `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` variables move these folders. `OMABIB_DB` and `OMABIB_SOCKET` point Omabib at a separate library, for testing.

```bash
omabib backup /absolute/path/library-backup.db
omabib restore /absolute/path/library-backup.db --to /absolute/path/restored.db
```

A backup is a consistent copy, safe to make while Omabib runs; don't copy `library.db` by hand. `restore` checks the backup and writes it only to a new path. To switch to a restored library, quit Omabib and its service first.

## The command line

The `omabib` command does most of what the window does. On a minimal Linux system the installer names the fontconfig and freetype packages for this command, and the OpenGL, X11 and xcb packages for the window, then stops with nothing copied.

```bash
omabib open                      # show or hide the window (Super+Alt+B on Omarchy)
omabib add                       # open the add box
omabib search 'network estimation'
omabib import references.bib
omabib status
omabib lookup CITATION_KEY       # preview online metadata, save nothing
omabib schema                    # every operation agents and scripts can call
```

`omabib call OPERATION` runs any operation with JSON on standard input; see [API.md](../API.md).

On Omarchy, **Super+Alt+B** runs `omabib open`. When `omarchy` is on your PATH, the installer appends this block to `~/.config/hypr/bindings.lua` if the `-- omabib-keybind` marker is not already there:

```lua
-- omabib-keybind
o.bind("SUPER + ALT + B", "Omabib", "omabib open")
```

A second install does not add another copy. If the file already uses that chord and does not have the marker, the installer leaves it unchanged and says so. If the file is missing, it is created with Omarchy's header comment and this block only. The Add action does not show this key.

## Projects, notes and agent access

Each reference has a stable ID and a separately editable citation key. Bibliographic facts are shared, while notes belong to a project or to the paper in general, with optional labels and evidence, where they came from, and a revision history. Different projects can judge the same paper differently.

The command line takes structured JSON on standard input, which avoids shell-quoting trouble:

```bash
omabib call create_project <<'JSON'
{"name":"My project","roots":["/absolute/project/path"]}
JSON

omabib call add_note <<'JSON'
{"ref_id":"REFERENCE_UUID","project_id":"PROJECT_UUID","body":"Potential methodological comparison for this project.","labels":["method"],"evidence":"PDF p. 7","provenance":"human","idempotency_key":"A_UNIQUE_REQUEST_ID"}
JSON
```

A project's `roots` let agents working in that folder find it with `list_projects`. A general note uses `"project_id": null`. Updating a note takes its `id` and `expected_revision`, and a stale revision fails. Repeating a request with the same idempotency key returns the earlier result.

For agents:

- Search returns eight results by default and up to 25 per page; `cursor` continues.
- Within a project, metadata is searched everywhere, but note bodies only from that project and general notes, unless `include_other_projects` is set.
- Fetching a reference leaves out notes and attachments unless asked. `get_references` fetches up to 25 at once, in order.
- `project_context` returns up to 8,000 characters and a cursor for more.
- Omabib never runs a language model itself and never indexes PDF text. It returns paths; reading the paper is up to the agent.
- The MCP server handles up to eight calls at once, plus eight queued; beyond that, calls get a retryable busy error. Responses can arrive out of order.
- Deleting a reference or a note goes through a preview first (`delete_reference_preview`, `delete_note_preview`), and the deletion must match it.

`omabib schema get_reference search` prints those tools' schemas. See [API.md](../API.md) for the rest.
