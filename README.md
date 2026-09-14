# Omabib

A native Omarchy bibliography picker with a Rust service, SQLite search, and project-aware research notes.

## Use it

Open **Super+B** on the configured desktop, or run `omabib open`. Type a title, author, abstract term, citation key, or note fragment. Enter opens the PDF or reference link. Tab opens details. Ctrl+K opens actions. Ctrl+O also opens the selected PDF or reference link. Set `OMABIB_PDF_SHORTCUT` in the shell launch environment to change this shortcut. Esc returns or closes.

Use the book icon in the top bar or Super+B to open Omabib. In Actions, type **1–17** to select a numbered command. For action 1, press Enter immediately or wait 700 ms; type a second digit to select 10–17.

Choose **6 · Import BibTeX file** to browse folders or paste an absolute file path. Enter opens a folder or imports a file; Ctrl+L focuses the path. **5 · Paste BibTeX** remains available.

Use Actions to add a DOI, create projects, write notes, or copy bibliographies. DOI lookup is a preview; import is a separate action. No abstract is invented when metadata lacks one.

Imports automatically consolidate repeated citation keys and identical entries within a file. Missing fields are combined; the first nonempty value wins when duplicates disagree, with conflicts reported. Entries with different DOIs remain separate. The importer also repairs unambiguous missing field commas, repeated fields, and a leading UTF-8 BOM. It retains the original imported text and leaves existing notes intact. Unclosed braces or undefined macros still produce an error instead of guessing or silently dropping records.

To import a file:

```bash
omabib import references.bib
omabib search 'network estimation'
omabib status
```

The normal library starts empty. Test fixtures and benchmarks use separate databases and are not imported into it.

## Build and install

Requires Rust, a C compiler, Omarchy's Quickshell shell, and systemd user services. Cargo.lock pins dependencies; SQLite with FTS5 is bundled.

```bash
cargo build --release --locked
./scripts/install.sh
codex mcp add omabib -- "$HOME/.local/bin/omabib" mcp
```

The installer manages only the Omabib binary, plugin, service and skill. It does not replace existing Hyprland shortcuts. The local installation has Super+B configured; on another machine, inspect available bindings and add `omabib open` to a free shortcut.

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

The stdio MCP server exposes ten tools: `search`, `get_reference`, `project_context`, `list_projects`, `add_note`, `update_note`, `export_bibtex`, `add_pdf`, `pull_pdf`, and `remove_pdf`. Restart/reconnect the MCP client after registration if it has not discovered the tools. The installed `omabib` Codex skill teaches selective retrieval and evidence-aware note writing.

- Search defaults to eight results, capped at 25 per page. `cursor` continues the result set.
- With a project, metadata is searched globally but note bodies are limited to global/current-project notes. Explicit `include_other_projects` broadens note search.
- Without a project, search can discover notes from all projects, with attribution.
- Fetching a reference does not include notes or attachments unless requested. Other-project note bodies remain opt-in.
- `project_context` defaults to 8,000 serialized characters. Follow its reference cursor; fetch a reference to obtain additional or unabridged notes.
- The service never launches an LLM or extracts/indexes PDF text. It can validate, download, archive and restore PDF files. Paths are returned to agents; reading the paper remains their responsibility.

`omabib schema` prints tool schemas and available CLI-only operations. See [API.md](API.md) for metadata, export and attachment operations.

## Search behavior and performance

SQLite word/prefix and trigram indexes generate candidates. A separate title/author/key pass protects those matches. Rust ranks a bounded candidate set by field weight and a modest project boost. Exact keys/DOIs precede keyword, substring and typo stages. SymSpell handles one-edit misspellings for words of at least four characters, using library vocabulary. Numeric identifiers are excluded from typo dictionaries.

This deliberately avoids exhaustive BM25 sorting of every match on every keystroke. Broad queries return a bounded ranked selection; the UI indicates when narrowing is useful. This is not a globally exhaustive relevance ordering. Blank-query browsing uses citation-key order. Typo vocabulary initializes in the background so keyword search can start immediately.

Results include a short matching excerpt and attributed note matches. Search never sends full PDFs or the entire note collection to an agent.

See [VERIFICATION.md](VERIFICATION.md) for measured results, test coverage and remaining limits. The synthetic scale fixture does not establish real-world search relevance.

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
omarchy plugin validate plugin
python scripts/benchmark.py --directory /absolute/scratch/benchmark --binary target/release/omabib
```

The benchmark refuses to overwrite a database and uses synthetic metadata. `scripts/test_ui.py` is an opt-in live keyboard test requiring an isolated socket; it interacts with the desktop and should run while no one else is typing.

V1 excludes automatic multi-computer metadata merging, embeddings, PDF indexing/annotation, and remote ChatGPT connectivity.

## Git history and PDF archive

The configured private repository is [atomashevic/omabib-history](https://github.com/atomashevic/omabib-history), checked out at `~/.local/share/omabib/history`. It stores structured reference metadata, project relationships, Markdown notes, note revisions, and LFS-managed PDF copies. The live SQLite database stays outside Git.

Run `omabib-history` to save a local snapshot commit, or `omabib-history --push` to also upload it. Snapshots and pushes are explicit, not scheduled. The command copies linked PDFs; PDFs placed directly in the repository can also be committed, but must be linked in Omabib to establish a reference association. There were 1,583 references, no notes and no linked PDFs at repository creation.

## Sync, repository settings, and PDFs

Use **Sync** in the search header to export, commit and push the current library. **Repo** edits the existing checkout path, origin URL and branch. Actions **15** and **16** open these features by number. The checkout must track PDFs with Git LFS. Saving a new remote URL changes that checkout's `origin`. Configuration is stored beside the database in `history-config.json`.

Sync preserves local edits and refuses divergent pushes; it never force-pushes or merges remote metadata into SQLite. The operation runs off the search thread and shows progress/errors. `omabib-history` now uses this same repository configuration.

Open an entry with Tab and choose **Attach PDF**, or use action **9**. The browser accepts an existing local PDF. Each attachment has **Open**, **Pull** when its path is missing, and **Remove link**. Removing a link keeps the file and its Git/LFS history.

```bash
omabib repo show
omabib repo set /absolute/path/history https://github.com/owner/repo.git --branch main
omabib sync                  # snapshot, commit, push
omabib sync --local          # local snapshot commit
omabib pdf add CITATION_KEY /absolute/path/paper.pdf
omabib pdf pull --attachment ATTACHMENT_UUID
omabib pdf pull --reference CITATION_KEY --url https://example.org/paper.pdf
omabib pdf remove ATTACHMENT_UUID
```

Pulling by attachment ID fetches its archived Git LFS copy and updates that attachment's path while preserving its ID. It requires that attachment to exist in the local library and have been synced previously. Pulling a supplied HTTPS URL downloads and attaches a validated PDF. Downloads/restored files live under the library's `pdfs/` directory; the maximum file size is 512 MiB. Local PDF linking does not upload anything until Sync is requested.

The MCP tools `add_pdf`, `pull_pdf`, and `remove_pdf` expose the same operations. Existing MCP clients may need to reconnect after updating the executable to discover them.


## Online metadata and opening references

Enter opens an existing attached PDF, then the bibliographic URL/PDF link, then the DOI landing page. Missing local PDFs fall back to the available web link. Copying a citation key remains action 1 in Ctrl+K.

Select a reference, open its details with Tab, and choose **Fill metadata**, or use action **17**. Crossref looks up DOIs or returns five title/author/year candidates. DataCite handles repository DOIs, including arXiv URLs/eprints. Europe PMC supplements a missing abstract for the selected DOI. No API key is required. Gateway coverage varies; unavailable fields remain missing.

Review the matching record and choose **Fill missing fields** (Ctrl+Enter). Existing values, citation keys, IDs, attachments and notes are preserved. Concurrent edits reject stale previews. Nothing is fetched during normal search and no bulk enrichment is run automatically.

`omabib lookup CITEKEY` returns the unsaved candidate preview. JSON CLI operations are `lookup_metadata` (`id`), `supplement_metadata` (`id`, `doi`), and `apply_metadata` (`id`, `expected_revision`, `fields`, `source`, optional `idempotency_key`). Apply accepts missing bibliographic fields only and records the source. `open_target` (`id`) resolves the preferred target without launching it.

Gateway documentation: [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/rest-api/), [DataCite REST API](https://support.datacite.org/docs/rest-api), [Europe PMC](https://europepmc.org/RestfulWebService).
