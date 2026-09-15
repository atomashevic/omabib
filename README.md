# Omabib

A native Omarchy bibliography picker with a Rust service, SQLite search, and project-aware research notes.

## Supported setup

Omabib currently supports **Omarchy with its Quickshell plugin system**, **Zathura** for PDFs, and **Codex CLI or ChatGPT Desktop in Codex mode** for reference-aware chats. Other desktop shells, PDF viewers, and ChatGPT modes have not been tested. The ChatGPT button opens a draft in Desktop's Codex mode with **GPT-5.6 Sol Medium** selected. Press Send to start that chat.

Install Rust/Cargo, a C compiler, Git, Zathura with a PDF backend, and Codex CLI. ChatGPT Desktop is optional. On Omarchy, install Zathura with your package manager, then build and install the plugin and service:

```bash
git clone https://github.com/atomashevic/omabib.git
cd omabib
./scripts/install.sh
xdg-mime default org.pwmt.zathura.desktop application/pdf
omarchy plugin validate "$HOME/.config/omarchy/plugins/omabib"
omabib status
```

The installer copies the Rust CLI, user service, Quickshell plugin, launch helpers, and Omabib skill into user-owned locations. It enables the user service and plugin. It does not change Hyprland keybindings. After checking that the keys are free or intentionally replacing them, add the following to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + B", "Omabib bibliography", "omabib open")
o.rebind("SUPER + W", "Close Omabib or window", "omabib-close-first")
o.bind("SUPER + ALT + B", "Omabib: add reference", "omabib add")
o.bind("SUPER + N", "Omabib: PDF note", "omabib-quick-note")
```

Run `hyprctl reload` and `hyprctl configerrors`, then open Omabib with Super+B. If your shell keeps an older cached plugin, run `omarchy restart shell` when no Omabib editor is open. To enable Codex MCP separately, use the private companion repository [omabib-mcp](https://github.com/atomashevic/omabib-mcp), or run `codex mcp add omabib --env "OMABIB_SOCKET=$XDG_RUNTIME_DIR/omabib/socket" -- "$HOME/.local/bin/omabib" mcp`.

## Typical uses

- Sort by newest addition to scan fresh Scholar alerts, then narrow the search to a project.
- Open a paper in Zathura, press Super+N, capture a page-aware text note or image clip, and keep its project context.
- Open the paper from Zathura with Super+B, or use the detail pane to inspect its abstract, notes, PDF, and AlphaXiv overview.
- Press the terminal button for a CLI chat (Codex or Claude Code) or the chat button for a desktop chat (ChatGPT or Claude Desktop). Both receive a private reference snapshot with all project-labelled notes, image clips, and PDF paths, plus Omabib MCP access to the same library.
- Ask an agent to compare project assessments, read a saved image clip, or retrieve the PDF. Library writes still require an explicit request.

## Use it

When Zathura is focused, **Super+B** opens the Omabib item attached to its exact PDF and shows the reference details in All references. An unlinked or ambiguous PDF opens ordinary search and shows a notification.

Open **Super+B** on the configured desktop, or run `omabib open`. An empty search field shows the newest additions first; **Ctrl+S** switches between date-added and citation-key order. Type a title, author, abstract term, citation key, or note fragment. Enter opens the PDF, or the reference link if there's no PDF. Ctrl+O opens the PDF specifically (downloading an open-access copy first if none is attached); Ctrl+U opens the reference's link/DOI specifically, skipping any attached PDF. Set `OMABIB_PDF_SHORTCUT` in the shell launch environment to change the PDF shortcut from Ctrl+O. Tab opens details. Ctrl+K opens actions. Esc closes the main popup; Q also closes it while the search field is empty, so searches can still contain q. Opening a link focuses the browser, and opening a PDF focuses the configured PDF viewer.

The popup has three panes. The **rail** on the left switches between all references (A–Z), recently added, projects and **Needs attention** (references missing an abstract or a PDF); below them are Add, Sync (its dot marks pending changes or a sync issue), the history repository and Actions. The **list** shows each result's title, authors and year with badges for PDF, AI overview, notes and a missing abstract; the filter button opens author, year, type and label filters. The **detail pane** has an icon toolbar (Open PDF, Open link, New note, AI summary, Codex, ChatGPT, then **⋯** for Fill metadata, Edit BibTeX, Assign to project, Attach PDF, copy formats and Delete) and five sections: **Overview** (abstract and metadata), **AI summary** (arXiv papers only), **Notes**, **Files** and **BibTeX**. Ctrl+1–5 select a section and Ctrl+Tab cycles through them. Titles, abstracts, notes and the AI summary use a proportional reading font, Noto Sans by default; set `OMABIB_READING_FONT` in the shell launch environment to change it. The abstract and the AI summary are selectable: drag to select across paragraphs and press Ctrl+C, or use their **Copy** buttons (the AI summary's copies the Markdown).

## Settings

The cog at the bottom of the rail (or Ctrl+K action **24**) opens Settings. Changes apply immediately and are saved in `$XDG_CONFIG_HOME/omabib/settings.json`; `omabib-settings` prints or changes them from a terminal (`omabib-settings set ai_cli claude`).

- **PDF viewer** lists the installed applications whose desktop entry opens PDFs. **System default** uses `xdg-open`. Another choice is started with `gtk-launch` from Omabib and from `omabib pdf open`. Page notes (Super+N) and opening Omabib from a PDF (Super+B) need Zathura.
- **Terminal chat** chooses **Codex CLI** or **Claude Code** for the toolbar's terminal button and action **22**.
- **Desktop chat** chooses **ChatGPT Desktop** or **Claude Desktop** for the toolbar's chat button and action **23**. Claude Desktop reads the library through Omabib's MCP server, which it loads from its own config: **Add Omabib to Claude Desktop** merges an `omabib` entry into `~/.config/Claude/claude_desktop_config.json`, keeps everything else, and saves the original once as `claude_desktop_config.json.omabib-backup`. Restart Claude Desktop afterwards.

## Tabs

The strip above the list starts with the **library tab**: the current project (or All references), its reference count, and a chevron for the project picker. Papers open in **paper tabs** beside it, each showing that paper's detail at full width. The toolbar, palette and shortcuts act on the paper in the active tab.

- **Open:** double-click a result, press **Ctrl+T** or **Ctrl+Enter** in search, or use the toolbar's new-tab button (Ctrl+K action **25**). Middle-click a result to open it in the background. A paper that is already open switches to its tab. Results that are open in a tab carry a *tab* badge.
- **Switch:** click a tab, **Ctrl+PgUp/PgDn** to cycle, **Alt+0** for the library tab and **Alt+1–9** for paper tabs. **Ctrl+F**, or typing while a paper tab is showing, returns to search. The search icon in a paper's toolbar finds it in the library tab.
- **Close:** tabs stay open until you close them, including after closing the popup or restarting the shell. Close one with its ×, a middle-click, **Ctrl+W** or action **26**. Deleting a reference closes its tab.
- **Limits:** at most 10 paper tabs; opening an eleventh is refused until one is closed. Tabs shrink as they fill the strip, and when they no longer fit they overlap, with the active tab on top.

Each paper tab remembers its section (Overview, AI summary, Notes, Files, BibTeX). Tabs are kept per library socket in `$XDG_STATE_HOME/omabib/tabs.json` (normally `~/.local/state/omabib/tabs.json`), storing only reference IDs, citation keys, titles and the section.

**Ctrl+K** opens the command palette. Type letters to filter it, or a number to run a numbered command as before; **1 · Add new item** is the DOI/arXiv/URL/BibTeX add box (see [Adding references](#adding-references)). For a first digit that could still start a two-digit action (1 or 2), press Enter immediately or wait 700 ms for a possible second digit.

Choose **7 · Import BibTeX file** to browse folders or paste an absolute file path. Enter opens a folder or imports a file; Ctrl+L focuses the path. **6 · Paste BibTeX** remains available.

Use the palette to add a DOI, create projects, write notes, or copy bibliographies. DOI lookup is a preview; import is a separate action. No abstract is invented when metadata lacks one.

Imports automatically consolidate repeated citation keys and identical entries within a file. Missing fields are combined; the first nonempty value wins when duplicates disagree, with conflicts reported. Entries with different DOIs remain separate. The importer also repairs unambiguous missing field commas, repeated fields, and a leading UTF-8 BOM. It retains the original imported text and leaves existing notes intact. Unclosed braces or undefined macros still produce an error instead of guessing or silently dropping records.

To import a file:

```bash
omabib import references.bib
omabib search 'network estimation'
omabib status
```

The normal library starts empty. Test fixtures and benchmarks use separate databases and are not imported into it.

## Adding references

Paste a DOI, an arXiv ID, a paper's URL, several of those separated by spaces/commas, or a whole BibTeX entry — into the search field itself (press Enter when there are no results and it's recognized), or **1 · Add new item** / Super+Alt+B. Omabib fetches title/author/year, an abstract when one can be found, and an open-access PDF link, previews the citation key it would assign (`family_word_year`, e.g. `watts_collective_1998`) alongside each item, and only writes on Import. Adding a single identifier fetches and attaches its PDF automatically; an identifier already in the library is filled in rather than duplicated. After Import, the added (or first, for several) reference becomes the current search and detail view.

For an arXiv paper, the **AI summary** tab checks alphaXiv for a published overview, caches it on first open, and lays the report out for reading: numbered section headings, lists, quotes and tables, with a strip that jumps between sections. Later opens use the local cache. alphaXiv reports open either with a `# Research Report:` title or with a sentence of prose before `### 1. Authors`; both are accepted, and anything served as HTML is rejected. When no overview exists the tab says so and links to the paper on alphaXiv; the reference is unchanged.

**Delete…** in the detail pane's **⋯** menu (or action **21** in Ctrl+K) previews the exact citation key and counts of notes, attachment links, project links, and cached summaries before confirmation. Deletion removes the reference and those library records atomically. PDF files stay on disk, and the history repository is not changed by this action. The MCP tools `delete_reference_preview` and `delete_reference` expose the same reviewed operation; deletion requires the current revision and note/attachment counts from the preview, the exact citation key, and an idempotency key.

Each note card in the Notes tab has edit and delete icons. Its confirmation shows the project and a note excerpt. Deleting one note removes its saved image clip and revisions but keeps the reference and its other notes. The MCP tools `delete_note_preview` and `delete_note` provide the same operation with a current note revision, matching reference ID, and idempotency key.

With **Codex CLI** selected, the terminal button in the detail toolbar (or Ctrl+K action **22**) opens a separate Codex CLI terminal for that entry. It passes a private context file containing metadata, BibTeX, all project-labelled notes, PDF/attachment paths, and exported image clips. Images are available for inspection on demand; MCP can retrieve current data and saved clips from the same library. The active project is the default scope for notes you ask Codex to save. Codex starts by acknowledging the entry, then waits for your question.

With **ChatGPT Desktop** selected, the chat button (or Ctrl+K action **23**) opens a prefilled chat in ChatGPT Desktop Codex mode. It uses a stable Omabib workspace per library with `gpt-5.6-sol` and medium reasoning, a local Omabib skill, MCP pointed at that library, and a private snapshot for each entry. The draft remains unsent until you press Send.

With **Claude Code** selected, the terminal button opens `claude` in a separate terminal with the same private context folder, the same opening prompt, and a per-launch MCP config (`mcp.json` in that folder) pointing at this library. Snapshots are kept under `$XDG_DATA_HOME/omabib/claude`. With **Claude Desktop** selected, the chat button opens a new Claude Desktop chat (`claude://claude.ai/new?q=…`) whose prompt asks Claude to load the entry, its notes, clips and PDF through Omabib's MCP tools, since Claude Desktop cannot read the local context file.

The Codex terminal requires `codex` and `xdg-terminal-exec`. The chat uses **gpt-5.6-sol** with **medium** reasoning and a per-launch Omabib MCP override. Context snapshots are retained under `$XDG_DATA_HOME/omabib/codex/chat-*` (normally `~/.local/share/omabib/codex`) so a resumed chat can still read its files. The stable parent directory is the Codex working directory; Codex may ask you to trust it on first use. Each note body is bounded at 65,536 characters and explicitly marked if truncated.

The library tab's chevron (or the rail's folder icon, or **Ctrl+P**) filters the whole result list to one project. Changing it keeps the current search text. If the focused reference is outside the new project, the detail pane closes and focus returns to search. **Assign to project** (the **+ project** chip or the **⋯** menu) opens a separate project picker, including when All references is selected.

```bash
omabib add 10.1145/3025453.3025717                    # by DOI
omabib add arXiv:1706.03762 --project PROJECT_ID       # by arXiv ID, linked to a project
omabib add https://example.org/paper                   # by URL, scraping its citation_ metadata
omabib add --pdf /absolute/path/to/paper.pdf            # identified from the PDF's own DOI/arXiv ID or title
omabib add --dry-run 10.1145/x 10.1145/y                # preview several at once, writes nothing
```

Without a PDF or identifier, `omabib add` opens the desktop popup's add box. `add --no-pdf` skips the automatic download. The JSON operation is `add_reference` (also an MCP tool); `preview_entry` previews without writing, and is what the popup calls before Import. `identify_pdf` reads a PDF's first two pages for a DOI/arXiv ID, or falls back to a Crossref title search using its Title metadata.

## Build and install

Requires Rust, a C compiler, Omarchy's Quickshell shell, and systemd user services. Cargo.lock pins dependencies; SQLite with FTS5 is bundled.

```bash
cargo build --release --locked
./scripts/install.sh
codex mcp add omabib -- "$HOME/.local/bin/omabib" mcp
```

The installer manages the Omabib binary, plugin, service, skill, and the `omabib-close-first` and `omabib-quick-note` helpers. It does not replace existing Hyprland shortcuts. The local installation has Super+B to open and Super+W to close Omabib first, then the focused window when Omabib is hidden. On another machine, inspect available bindings before adding either shortcut. Set `application/pdf` to Zathura, the PDF viewer supported by the page-aware note workflow.

After an update, the plugin normally reloads through `omarchy-shell shell rescanPlugins`. If Quickshell retains cached component code, `omarchy restart shell` loads the new version. Do not restart while the desktop is locked.

Data is stored at `$XDG_DATA_HOME/omabib/library.db`, defaulting to `~/.local/share/omabib/library.db`. The socket is `$XDG_RUNTIME_DIR/omabib/socket`. `OMABIB_DB` and `OMABIB_SOCKET` override these paths for isolated libraries. The UI uses `OMABIB_SOCKET` from its process environment and also accepts `socket_path` in its summon payload for isolated testing.

## Project notes and agent access

Each reference has a stable UUID and a separately editable citation key. Global bibliographic facts are shared. Notes have an explicit project or global scope, optional labels/evidence, provenance, and a revision history. Multiple projects can assess the same reference differently.

The CLI accepts structured JSON on stdin, avoiding shell-quoting problems:

```bash
omabib call create_project <<'JSON'
{"name":"My project","roots":["/absolute/project/path"]}
JSON

omabib call list_projects <<'JSON'
{"cwd":"/absolute/project/path"}
JSON
```

Use returned UUIDs in subsequent calls:

```bash
omabib call add_note <<'JSON'
{"ref_id":"REFERENCE_UUID","project_id":"PROJECT_UUID","body":"Potential methodological comparison for this project.","labels":["method"],"evidence":"PDF p. 7","provenance":"human","idempotency_key":"A_UNIQUE_REQUEST_ID"}
JSON
```

A global note explicitly uses `"project_id": null`. An update supplies `id` and `expected_revision`, as well as the current body, scope, provenance, labels and evidence. Stale revisions fail. Repeating the same request and idempotency key returns the previous result; reusing a key for different content fails.

The stdio MCP server exposes search, retrieval, note, PDF, reference, and deletion tools. Use `omabib schema` for the current tool list and schemas; reconnect the MCP client after updating the executable. The installed `omabib` Codex skill covers selective retrieval, evidence-aware notes, reviewed deletions, adding references, and reading PDFs through `get_pdf`.

- Search defaults to eight results, capped at 25 per page. `cursor` continues the result set.
- With a project, metadata is searched globally but note bodies are limited to global/current-project notes. Explicit `include_other_projects` broadens note search.
- Without a project, search can discover notes from all projects, with attribution.
- Fetching a reference does not include notes or attachments unless requested. Other-project note bodies remain opt-in.
- `project_context` defaults to 8,000 serialized characters. Follow its reference cursor; fetch a reference to obtain additional or unabridged notes.
- The service never launches an LLM or extracts/indexes PDF text. It can validate, download, archive and restore PDF files. Paths are returned to agents; reading the paper remains their responsibility.

`omabib schema` prints tool schemas and available CLI-only operations. See [API.md](API.md) for metadata, export and attachment operations.

## Search behavior and performance

SQLite word/prefix and trigram indexes generate candidates. A separate title/author/key pass protects those matches. Rust ranks a bounded candidate set by field weight and a modest project boost. Exact keys/DOIs precede keyword, substring and typo stages. SymSpell handles one-edit misspellings for words of at least four characters, using library vocabulary. Numeric identifiers are excluded from typo dictionaries.

This deliberately avoids exhaustive BM25 sorting of every match on every keystroke. Broad queries return a bounded ranked selection; the UI indicates when narrowing is useful. This is not a globally exhaustive relevance ordering. With an empty search field, the popup shows newest additions first; click the sort button or press **Ctrl+S** to switch to citation-key order. The date-added order uses a SQLite index and pages without sorting the whole library. Search terms keep relevance ranking. Typo vocabulary initializes in the background so keyword search can start immediately.

Results include a short matching excerpt and attributed note matches, plus `has_pdf` and `has_abstract`. Search never sends full PDFs or the entire note collection to an agent.

See [VERIFICATION.md](VERIFICATION.md) for measured results, test coverage and remaining limits. The synthetic scale fixture does not establish real-world search relevance.

## Abstracts

An identifier match (DOI, arXiv ID, or a URL that resolves to one) looks for an abstract automatically: the primary record (Crossref or DataCite) if it has one, otherwise OpenAlex, then Semantic Scholar, then Europe PMC — the first gateways not every publisher registers an abstract with. This runs for `add_reference`, the popup's add box, and **17 · Fill metadata**; the abstract's source is reported alongside it.

To backfill existing references that have an exact DOI or arXiv ID but no abstract yet:

```bash
omabib enrich --abstracts --dry-run --limit 20   # preview, writes nothing
omabib enrich --abstracts                        # fill the whole library, ~1 request/second
```

It prints progress per reference to stderr and a summary (filled, by source; not found; skipped for lacking an identifier; failed) to stdout. It's resumable — already-filled references are skipped — so interrupting and rerunning is safe.

## Backup, restore and removal

```bash
omabib backup /absolute/path/library-backup.db
omabib restore /absolute/path/library-backup.db --to /absolute/path/restored.db
```

Backups use SQLite's consistent backup API. Restore validates the backup and only writes a new path. Stop the service before deliberately replacing the active library with a restored file. Do not copy a live database without its WAL; use `backup` instead. Future schema upgrades must take a backup before changing an existing schema. This release creates schema 1 and refuses newer versions.

Removal preserves your library:

```bash
systemctl --user disable --now omabib
omarchy plugin disable omabib
codex mcp remove omabib
```

Then remove only the Omabib binary, user service, plugin directory, skill, and its named shortcut if desired. The data directory remains independent of the plugin.

## Verification commands

```bash
cargo test --locked
cargo clippy --all-targets -- -D warnings
python scripts/test_transport.py target/release/omabib
python scripts/test_history_integration.py target/release/omabib
omarchy plugin validate plugin
python scripts/benchmark.py --directory /absolute/scratch/benchmark --binary target/release/omabib
```

`scripts/test_metadata.py target/release/omabib` makes live requests to Crossref/DataCite/OpenAlex/Semantic Scholar/Europe PMC/arXiv against a temporary, isolated library; run it only when checking those gateways specifically, since a busy run can hit Crossref's rate limit. The benchmark refuses to overwrite a database and uses synthetic metadata. `scripts/test_ui.py` is an opt-in live keyboard test requiring an isolated socket; it interacts with the desktop and should run while no one else is typing. `scripts/test_tabs_ui.py` is the same kind of test for the detail tabs, the cached AI summary, the project menu and the command palette. `scripts/test_claude.py target/release/omabib` checks the Claude Code and Claude Desktop handoffs and the settings helper against an isolated library and a temporary config directory.

The UI components render offscreen without a desktop: `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml/imports -input tests/qml` loads them against stub `qs.Commons`/`qs.Ui` modules and a stand-in for `App.qml`, and saves screenshots of every tab to `/tmp/omabib-qml-shots`. `node scripts/test_overview_text.js [overview.md]` tests the AI summary's Markdown renderer, optionally on a real overview file.

V1 excludes automatic multi-computer metadata merging, embeddings, and remote ChatGPT connectivity. `identify_pdf` reads a PDF's first two pages to recognize an identifier or search by title, but that text is never stored or indexed for search — full-text PDF indexing and annotation remain out of scope.

## Git history and PDF archive

The configured private repository is [atomashevic/omabib-history](https://github.com/atomashevic/omabib-history), checked out at `~/.local/share/omabib/history`. It stores structured reference metadata, project relationships, Markdown notes, note revisions, and LFS-managed PDF copies. The live SQLite database stays outside Git.

Run `omabib-history` to save a local snapshot commit, or `omabib-history --push` to also upload it. Snapshots and pushes are explicit, not scheduled. The command copies linked PDFs; PDFs placed directly in the repository can also be committed, but must be linked in Omabib to establish a reference association. There were 1,583 references, no notes and no linked PDFs at repository creation.

## Repository setup

`omabib repo check [PATH]` reports whether `git`, `git-lfs` and `gh` are installed, whether `gh` is logged in, and — with a path — its state (missing, empty, not a Git repository, or a repository with its LFS/branch/origin/dirty status). Use it, or the **Repo** dialog's live summary, before setting one up.

```bash
omabib repo init NAME [--path PATH] [--branch main]     # create a new private GitHub repo
omabib repo use PATH [--remote URL] [--branch main] [--fix-lfs]   # adopt an existing checkout
omabib repo show
```

`repo init` requires `gh` to be installed and logged in (`gh auth login`); it scaffolds the checkout (`.gitattributes`/`.gitignore` for Git LFS, a README, `tools/snapshot.py`), makes the initial commit, and creates the GitHub repository from it. `repo use --fix-lfs` runs `git lfs install --local` and adds the LFS tracking lines itself when the checkout doesn't have them yet, rather than only refusing. Configuration is stored beside the database in `history-config.json`. The desktop **Repo** dialog offers both paths with the same live checks.

## Sync and status

Use the header status chip in the search popup (or action **19**) to sync: export, commit and push the current library. It reads "Set up sync", "✓ Synced 2h ago", "● Changes pending", "↓ N behind" or "⚠ Sync issue" depending on `repo_status`. Action **20** opens repository settings.

Sync preserves local edits and refuses divergent pushes; it never force-pushes or merges remote metadata into SQLite. A push that fails *after* a successful local commit is reported as such (`ok:false, committed:true`) rather than losing the commit — fix what's described and sync again. The operation runs off the search thread. `omabib-history` uses this same repository configuration.

```bash
omabib sync                  # snapshot, commit, push; readable summary + exit code
omabib sync --local          # local snapshot commit only
omabib sync --json           # raw result
omabib repo status [--fetch] [--json]
```

`repo_status` (also the JSON operation) reports the current HEAD, how far ahead/behind the remote, local edits, pending changes since the last successful sync, and the last attempt's result or a classified error (`diverged`, `auth`, `network`, `lfs`, `dirty`, `branch`, `origin-changed`, `busy`, `unknown`) with a hint — `diverged`, for instance, points at `git pull --rebase`, since Omabib itself never merges.

## Quick PDF notes

Focus a PDF in Zathura and press **Super+N**. Drag a rectangle for an image, or click without dragging for a text note. Escape cancels selection. The compact quick note editor shows the reference title and current PDF page, prefills the evidence location, and keeps the project used when opening the PDF (or Global). **Ctrl+Enter** saves; **Esc** cancels and returns to the PDF. No note is written until Save.

The shortcut checks the foreground Zathura PID, window title, and exact document path against the remembered reference's PDF attachments. If that context is missing or does not match, it resolves the PDF through Omabib's exact attachment-path index. Missing or ambiguous matches stop without creating a note. Page numbers are physical PDF pages, counted from 1. This also restores reading context after a shell restart. `omabib-quick-note --print` validates the current context without opening or saving a note. The helper requires Python with PyGObject, and Zathura's D-Bus interface.

## Visual notes

Press **Super+N** while reading the reference's PDF and select a region inside Zathura. A compact popup opens with a lossless PNG preview. A click without dragging opens a text-only note instead. Add optional commentary and press **Ctrl+Enter** to save, or **Esc** to discard. Recapture (Ctrl+Shift+C) and Remove are available before saving. Capture is rejected if the original document/page changes or the rectangle extends outside its window.

Clips are stored atomically with their notes in SQLite, included in database backups, and exported as `notes/images/*.png` by history snapshots. Ordinary note/search responses carry compact image metadata. The MCP tool **get_note_image** returns the original PNG as an image content block for reading numbers, math, text, or code. Image-only notes are supported; the captured PDF page and source path remain attached. No OCR is required at capture time. The first release supports one PNG per visual note, up to 8 MiB and 32 million pixels. Capture requires `slurp` and `grim`.

## PDFs

Open an entry with Tab and choose **Attach PDF…** in the Files tab, or use action **10**, to link an existing local file. Use **Open PDF** (Ctrl+O, action **12**) to have Omabib find one itself — an existing attachment, one restored from the history archive, or a freshly downloaded open-access copy (the reference's own link, an arXiv direct link, OpenAlex, or Semantic Scholar) — and open it; **Open link** (Ctrl+U, action **11**) opens the reference's own URL/DOI instead, even if a PDF is attached; **Copy PDF path** (action **13**) copies the PDF's path without opening it. Each attachment also has **Open**, **Pull** when its path is missing, and **Remove link**; removing a link keeps the file and its Git/LFS history.

Downloaded and restored PDFs are stored as `pdfs/<citekey>.pdf` (e.g. `pdfs/watts_collective_1998.pdf`), with a short hash suffix only on a genuine name collision — not a content hash, so they're findable by browsing. The history repository keeps its own separate content-addressed naming.

```bash
omabib pdf add CITATION_KEY /absolute/path/paper.pdf
omabib pdf get CITATION_KEY [--no-download]     # print a readable local path
omabib pdf open CITATION_KEY                     # ...and open it
omabib pdf pull --attachment ATTACHMENT_UUID
omabib pdf pull --reference CITATION_KEY --url https://example.org/paper.pdf
omabib pdf remove ATTACHMENT_UUID
```

Pulling by attachment ID fetches its archived Git LFS copy and updates that attachment's path while preserving its ID. It requires that attachment to exist in the local library and have been synced previously. Pulling a supplied HTTPS URL downloads and attaches a validated PDF. Downloads/restored files live under the library's `pdfs/` directory; the maximum file size is 512 MiB. Local PDF linking does not upload anything until Sync is requested.

The MCP tools `add_pdf`, `pull_pdf`, `remove_pdf`, and `get_pdf` expose these operations to agents. Existing MCP clients may need to reconnect after updating the executable to discover them.


## Online metadata and opening references

Enter opens an existing attached PDF, then the bibliographic URL/PDF link, then the DOI landing page. Missing local PDFs fall back to the available web link. Copying a citation key is action **2** in Ctrl+K.

Select a reference, open its details with Tab, and choose **Fill metadata**, or use action **14**. Crossref looks up DOIs or returns five title/author/year candidates. DataCite handles repository DOIs, including arXiv URLs/eprints. A missing abstract is then looked for via OpenAlex, Semantic Scholar and Europe PMC, in that order, stopping at the first substantial one. No API key is required for any of these. Gateway coverage varies; unavailable fields remain missing.

Review the matching record and choose **Fill missing fields** (Ctrl+Enter). Existing values, citation keys, IDs, attachments and notes are preserved. Concurrent edits reject stale previews. Nothing is fetched during normal search and no bulk enrichment is run automatically — see [Abstracts](#abstracts) for the explicit, opt-in `omabib enrich --abstracts` backfill.

`omabib lookup CITEKEY` returns the unsaved candidate preview. JSON CLI operations are `lookup_metadata` (`id`), `supplement_metadata` (`id`, `doi`), `lookup_abstract` (`id`; a single reference's abstract-only preview by its exact DOI/arXiv ID), and `apply_metadata` (`id`, `expected_revision`, `fields`, `source`, optional `idempotency_key`). Apply accepts missing bibliographic fields only and records the source. `open_target` (`id`) resolves the preferred target without launching it; `get_pdf` (`id`, optional `download`) resolves — and, unless told not to, downloads — a readable PDF path.

Gateway documentation: [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/rest-api/), [DataCite REST API](https://support.datacite.org/docs/rest-api), [OpenAlex API](https://docs.openalex.org/), [Semantic Scholar Graph API](https://api.semanticscholar.org/api-docs/graph), [Europe PMC](https://europepmc.org/RestfulWebService).

If the remembered reference is unavailable or belongs to another PDF, Super+N resolves Zathura’s exact canonical PDF path through an indexed attachment lookup. It reconnects the popup to the matching library. Recovery starts at Global scope so an unrelated project is never carried over. Missing or ambiguous matches stop with a notification; matching basenames alone are insufficient.
