# JSON interface

All operations use `omabib call METHOD` with one JSON object on stdin. The socket protocol is newline-delimited JSON:

```json
{"v":1,"id":1,"method":"search","params":{"query":"network","limit":8}}
```

A response echoes `v` and `id`, with either `result` or `error.message`. Search requests on one connection supersede earlier searches. `cancel` cancels that connection's active search generation. SQL progress handlers interrupt superseded work. Clients must discard stale results as well.

## Search and reading

| Method | Parameters |
|---|---|
| `search` | `query`; optional `project_id`, `include_other_projects`, `limit` (1–25), `cursor`, `author`, `year` (string), `entry_type`, `project_filter`, `label`, `sort` (`added_desc` or `citekey` for blank-query browsing) |
| `get_reference` | `id` (UUID or citation key); optional `include_metadata` (default true), `include_notes`, `include_attachments`, `project_id`, `include_other_projects`, `note_limit`, `note_cursor`, `note_chars`, `include_history` |
| `project_context` | `project_id`; optional `query`, `cursor`, `max_chars` (1,000–32,000; default 8,000) |
| `list_projects` | optional `cwd`; returns all projects and longest-root resolution, or explicit ambiguity |
| `status` | none |

Search metadata is compact; a note match includes its project identity. The `ranking` field names the bounded scoring strategy. Broad candidate sets are identified by `candidate_limited`. Refine a query rather than assuming every matching record is present in that ranked selection.

Blank-query browsing uses `citekey` order by default for API compatibility. `sort:"added_desc"` returns newest additions first using an index on the stored `created_at` timestamp, with ID as a stable tie-breaker. The popup selects this order by default and lets the user switch to citation-key order. Search terms still use relevance ranking.

`get_reference` returns source field values and a normalized editable BibTeX-family representation. Notes are opt-in. `include_history` explicitly asks for prior revisions and is CLI-only. Full original import text is retained in the database. It always includes `pdf_path` (an existing local PDF, or `null`); full attachment detail stays opt-in via `include_attachments`. Search hits carry `has_pdf` and `has_abstract`.

## Adding references

| Method | Parameters |
|---|---|
| `preview_entry` | `input`: a DOI, arXiv ID, HTTP(S) URL, several of those separated by whitespace/commas, or one raw BibTeX entry. Never writes. Returns a combined `bibtex` (for backward-compatible callers) plus `items`, one per recognized identifier: `input`, `recognized` (`doi`\|`arxiv`\|`url`\|`bibtex`), `bibtex`, `citekey` (a `family_word_year`-style hint; the saved key can differ on a collision or a merge), `title`, `authors`, `year`, `source`, `abstract_source`, `pdf_url`, `warnings`. Unrecognized tokens are skipped and reported in a top-level `warnings` array rather than failing the whole call, unless nothing was recognized. |
| `add_reference` | `input` (as above) or `pdf_path` (an absolute local PDF, identified the same way as `identify_pdf`); optional `project_id`, `download_pdf` (default true — downloads an open-access PDF when the reference itself doesn't already have a local one), `idempotency_key` (required through MCP). All network work (identification, abstract/PDF lookup, download) happens before any write lock is taken; import, PDF attachment and project linking then happen in one transaction — nothing is written if attaching a supplied `pdf_path` fails. An identifier matching an existing reference by DOI or compatible citation key fills it rather than duplicating it (`merged:true`). Returns `id`, `citekey`, `merged`, `conflicts`, `repairs`, `abstract_source`, `attachment` (or `null`), `warnings`. |
| `identify_pdf` | `path`: an absolute local PDF. Reads its first two pages (`pdftotext`) for an embedded DOI or arXiv ID; without one, falls back to a Crossref title search using the PDF's Title metadata (`pdfinfo`) or its first substantial line of text. Returns `candidates` (shaped like a `preview_entry` item when an identifier was found directly, or like a `lookup_metadata` candidate — with `fields`/`additions`/`conflicts` — for a title-search match, which is marked `"match_kind":"pdf title search: verify the paper"` and needs review) and `pages`. Page text itself is never stored or indexed. |
| `preview_doi` | `doi`; returns raw BibTeX from the DOI registrar, current conflicts, proposed citation keys and `saved:false`. Superseded by `preview_entry`, which also accepts arXiv IDs, URLs and multiple identifiers; kept for existing callers. |

`omabib add ID...` (CLI) calls `add_reference` once per identifier; `omabib add --pdf FILE` calls it with `pdf_path`; `omabib add --dry-run` calls `preview_entry` instead. With no arguments it opens the desktop popup's add box, which does the same lookups interactively.

## Metadata and project writes

| Method | Parameters |
|---|---|
| `import_bibtex` | `bibtex` (up to 64 MiB), optional `source`, `idempotency_key` |
| `upsert_reference` | one-entry `bibtex`; for edits, `id` and `expected_revision`; optional `source`, `idempotency_key` |
| `delete_reference_preview` | `id` (UUID or citation key); read-only. Returns exact ID/key, current revision, and counts of notes, attachment links, project links, and cached summaries. |
| `delete_reference` | `id`, `expected_revision`, `confirm_citekey`, `expected_notes`, `expected_attachments`, `idempotency_key`. Removes the reviewed reference and its library children in one transaction; keeps local PDF files. With sync configured, the deletion propagates. A changed revision or child count rejects the request. |
| `create_project` | `name`; optional `description`, absolute `roots` array |
| `update_project` | `id`, `name`, `description`, `roots`; replaces these project fields |
| `associate` | `ref_id`, `project_id`, optional `labels`; replaces the association's labels |
| `attach` | `ref_id`, absolute `path`; optional `file_type` (default pdf), `fingerprint` |

Import results include `repairs`, `duplicates_merged`, and one `items` entry per resulting reference. Repeated citation keys within the input and identical input entries consolidate automatically, filling missing fields and reporting conflicting values; distinct DOIs prevent merging. Unambiguous missing field commas and repeated fields are repaired. Original import text is retained.

Imports are transactional. Known DOI identity and compatible citation-key records are reused; missing fields are filled, conflicting values are reported and preserved. Distinct identifiers do not merge just because keys collide. Renamed incoming cross-reference keys are adjusted. Missing dependencies make bibliography export fail explicitly.

Attachments are pointers, not file copies. Missing paths remain visible and can be relinked by adding a corrected path. No fingerprint is calculated implicitly.

## Notes

`add_note` requires `ref_id`, explicit `project_id` (UUID or null), `body` and `provenance`. Optional `labels` is an array of strings; `evidence` is a string. `update_note` requires the note `id` and `expected_revision` instead of a new reference ID. Updates preserve the previous snapshot in `note_revisions` and cannot silently overwrite a later revision.

`delete_note_preview {id}` returns the note's reference, project, revision, excerpt, and image presence without writing. `delete_note {id, expected_revision, confirm_ref_id, idempotency_key}` removes only that note, its image clip, revision history, and search row in one transaction. A stale revision or mismatched reference rejects the request. Both are MCP tools.

Supply all note fields being retained when updating. Note bodies are limited to 64 KiB. Use `idempotency_key` for retried writes; MCP requires that parameter. Adding a project-specific note also associates the reference with that project.

## Export and backup

- `export_bibtex`: `ids` or `project_id`; includes crossref/xref/xdata dependencies and returns `bibtex` plus `count`.
- `export_notes`: `ids` or `project_id`, optional `include_other_projects`; returns Markdown with reference, project, provenance, evidence and note/revision identifiers.
- `backup`: a new destination `path`; never overwrites an existing file.

For large exports, redirect CLI output to a file rather than loading it into an agent conversation. Public interfaces operate on stable UUIDs; citation keys remain convenient human-facing selectors.

## Sync and PDF operations

| Operation | Parameters and behavior |
|---|---|
| `sync_status` | Read-only. Returns whether storage is connected and the library has joined it, provider and location, state (`off`\|`idle`\|`syncing`\|`offline`\|`auth`\|`full`\|`error`), message/progress, last success, pending changes, conflicts, known devices, and local/cloud-only PDF counts. |
| `sync_providers` | Read-only. Returns rclone availability/version/config path, configured advanced remotes, and the Drive, Dropbox, OneDrive, folder and advanced choices. Drive is unavailable until an Omabib Google client ID is built in or supplied through `OMABIB_GOOGLE_CLIENT_ID`. |
| `sync_connect` | `provider`: `drive`, `dropbox`, `onedrive`, `folder`, or `rclone`. Folder also requires absolute `path`; advanced rclone requires `remote`. Folder/advanced connections finish immediately. Cloud connections start browser authorization; poll `sync_status.connecting` or subscribe for status events. Connecting does not yet join or create a library. |
| `sync_connect_cancel` | Cancels an authorization in progress. |
| `sync_inspect` | Read-only after connecting. Reports whether an Omabib library exists in that storage, with record/PDF counts and recent devices. |
| `sync_start` | `mode`: `new`, `join`, `merge`, or `replace`. `new` initializes storage from this computer. The other modes load the remote snapshot; `merge` also uploads local-only records, while `replace` discards local library records after making a database backup. Returns current sync status. |
| `sync_now` | Flushes local edits, uploads immutable batches and files, downloads and applies other devices' batches, and returns `sent`, `received`, source devices, changed reference/note IDs and conflict count. If another sync owns the lock, returns `already_running:true` without changing its status or progress; otherwise `already_running:false`. |
| `sync_conflicts` | Read-only. Returns unresolved duplicate, note-copy and delete/edit conflicts. |
| `sync_resolve` | `id`, `action`. Actions depend on kind: `keep_both`, `keep_this`, `keep_other`, `restore`, or `dismiss`. Resolution uses ordinary library writes and therefore syncs. |
| `sync_download_all` | Downloads every PDF represented locally only by a sync placeholder. Returns downloaded count and failures. |
| `sync_disconnect` | Stops syncing this computer and keeps its local library unchanged. |
| `sync_nudge` | Requests a background cycle and returns status; used when the window opens. |
| `get_pdf` | `ref_id`; optional `download` (default true). Returns a locally readable `path` to a PDF: an existing attachment (`source:"local"`), one downloaded and checksum-verified from configured sync storage (`"cloud"`), or (unless `download:false`) a freshly downloaded open-access copy from the reference, arXiv, OpenAlex, or Semantic Scholar (`"downloaded"`). Returns a path, never PDF text. |
| `add_pdf` | Required `ref_id` (UUID or citation key), absolute `path`; optional `idempotency_key`. Returns the stable attachment `id`, reference ID and path. |
| `pull_pdf` | Either `attachment_id` to download and verify its file from configured sync storage, or `ref_id` and HTTPS `url` for a download. Optional `idempotency_key` for URL attachment writes. Returns attachment ID/path. |
| `remove_pdf` | Required `attachment_id`, optional `idempotency_key`. Unlinks only; `file_deleted` is false. |
| `get_attachment` | CLI-only lookup by attachment `id`. |

`add_pdf`, `pull_pdf`, `remove_pdf` and `get_pdf` are also MCP tools. Use `get_reference` with `include_attachments:true` to discover attachment IDs, or its always-present `pdf_path` when only a path is needed. Managed PDFs are stored locally as `pdfs/<citekey>.pdf`, with a short content-hash suffix only on a genuine name collision. Sync stores readable names under `Omabib/pdfs/`; attachment metadata carries the checksum and remote name. A pull preserves the attachment UUID and verifies the downloaded PDF against its SHA-256.

The live SQLite database is never copied to sync storage. Each device writes immutable change batches and its own manifest. Records merge by per-field hybrid logical clocks; conflicting note bodies retain a second note for review, delete/edit conflicts can be restored, duplicate DOIs remain separate and are flagged, citekey collisions receive deterministic suffixes, and same-name projects converge through aliases. Chats and note revision history remain local.

### Metadata and abstract enrichment, and opening

- `open_target {id}` resolves an existing PDF, HTTP(S) URL, or DOI URL, without launching it.
- `lookup_metadata {id}` returns up to five ranked online candidates with `fields`, `additions`, `conflicts`, `source`, `needs_abstract`, and (once found) `abstract_source`; top-level `id` and `expected_revision` identify the unchanged reference. For an identifier match (not a broad title search), a missing abstract and open-access PDF link are looked up automatically — trying the primary record (Crossref/DataCite), then OpenAlex, then Semantic Scholar, then Europe PMC — so a caller doesn't need a second round trip.
- `supplement_metadata {id, doi}` re-runs that same abstract lookup by exact DOI (or the DOI an arXiv ID infers into) for a selected candidate. Returns `fields`, `source`, `gateway` (which service supplied it, or `"none"`), and a `warning` when nothing was found. Never mixes in title-search results.
- `lookup_abstract {id}` previews an abstract for one reference that already has an exact DOI or arXiv identifier — the single-reference version of what `enrich --abstracts` loops over. Returns `abstract`, `source`, `expected_revision` (all `null`/absent-safe when nothing was found), without writing.
- `missing_abstracts` (CLI-only) lists references with no abstract yet (`id`, `citekey` pairs, optional `limit`, default/cap 5,000/20,000) plus a `total` count. Used by `enrich --abstracts` rather than a direct database read, so it always sees the exact database the service itself is writing to.
- `apply_metadata {id, expected_revision, fields, source, idempotency_key?}` fills only empty fields, keeps IDs/keys/notes/attachments, rejects stale revisions or DOI collisions, and updates the search index. Pass the reviewed candidate's additions and provenance. None of these operations is automatically invoked during search.

`omabib lookup REFERENCE` invokes `lookup_metadata`; `omabib enrich --abstracts [--limit N] [--dry-run]` loops `missing_abstracts` → `lookup_abstract` → `apply_metadata` across the library, about one request per second, resumable since already-filled references are skipped on a rerun. These operations are available through the JSON CLI; existing compact MCP tool discovery is unchanged (now 12 tools: the original 10 plus `get_pdf` and `add_reference`).

## Visual notes

`add_visual_note` (JSON/CLI) atomically creates a note and stores a PNG clip of a PDF page. Parameters: `ref_id` (UUID), explicit `project_id` (or null), `body` (may be empty), `provenance`, `source_pdf` (a PDF attached to the reference), `page` (1-based), optional `labels`/`evidence`/`idempotency_key`, and either `rect_pt` or `image_path`. With `rect_pt` (`{x, y, width, height}` in PDF points from the page's top-left corner, at least 1pt each) the service renders the region from the PDF with MuPDF at 216 dpi and stores the rectangle with `"unit":"pt"`; this is what reader tabs send. The older form passes `image_path` (an absolute PNG path) and a screen-pixel `rectangle`. Either way the PNG must be at most 8 MiB and 32 million pixels, and the source PDF must be attached to the reference. Reusing the same request key returns the saved note without rendering or reading the image again.

Notes returned by `get_reference` include optional compact `image` metadata. `get_note_image {note_id, project_id}` checks note scope and returns metadata plus base64 PNG `data` via JSON. MCP returns metadata as text and PNG as an `image` block. `update_note` edits commentary without altering the image. SQLite backups contain image bytes; sync stores clip PNGs by content hash.

`find_reference_by_pdf` (JSON/CLI, read-only) accepts `path`, resolves it canonically, and returns `ref_id` only for exactly one matching PDF attachment. Uses a partial attachment-path index; missing and ambiguous matches return errors.

`get_alphaxiv_overview` accepts a reference `id` for a modern arXiv paper. It returns a cached, source-labelled Markdown overview when available, otherwise fetches the first-party AlphaXiv overview with a 12-second timeout and stores it under the reference. A 404 returns `available:false`; other retrieval errors leave the cache unchanged. The operation is also available as an MCP tool. Cached overviews sync with the reference library.

`render_math` (JSON/CLI, no library access) renders LaTeX math for the UI's Markdown notes and overviews. It accepts `items` (at most 200 of `{tex, display}`), `color` (`#rrggbb`), `size_px` (6–72) and optional `scale` (1–4, default 2). Each item returns `{key, path, width, height}` for an SVG in `$XDG_CACHE_HOME/omabib/math/` (width and height in logical pixels; the file is `scale` times larger), or `{key, error}` for TeX that doesn't convert or lay out. Formulas are converted with mitex and typeset by Typst with its bundled fonts; results, including errors, are cached by TeX, mode, color, size and scale. Inline formulas are padded so they sit on the text baseline under `vertical-align: middle`.

`pdf_open` (JSON/CLI, read-only) opens a reference's PDF for a reader tab: `ref_id`, optional `attachment_id` (must be a PDF attachment of that reference) and `download` (default true; otherwise the first local PDF, one downloaded from sync storage, or an open-access copy found like `get_pdf`). It returns `doc_id`, `path`, `source`, `attachment_id`, `page_count`, `pages` (`{x0, y0, w, h}` in points), the PDF `title`, and a flat `outline` of `{title, level, page, uri}`. The `doc_id` changes when the file changes; the other `pdf_*` operations refuse a stale or unknown `doc_id` with "open it again".

`pdf_render` (`doc_id`, 1-based `page`, `scale`) renders a page to PNG in `$XDG_CACHE_HOME/omabib/pages/<doc_id>/` and returns `{path, width, height, scale, links}`. Scales snap to quarter steps between 0.25 and 8 so zooming reuses cached pages; the cache is capped at 500 MB. `links` are `{rect, page, uri}` with rectangles in points (`page` for internal links, `uri` for web and mail links). `pdf_text` (`doc_id`, `page`) returns `words` as `[text, x0, y0, x1, y1, block, line]`. `pdf_search` (`doc_id`, `query`) returns `hits` of `{page, rects}`, at most 500, with `total` and `truncated`. MuPDF runs on one service thread that keeps up to 8 documents open.

## Chat

Chats with Claude Code or Codex about one reference, run by the service. JSON/CLI only; the agents themselves reach the library through `omabib mcp`.

| Method | Parameters |
|---|---|
| `chat_start` | `ref_id` (UUID or citation key); optional `agent` (`claude`, the default, or `codex`), `project_id`, `model`, `effort` (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` or `ultra`; absent or empty uses the agent's default). Creates the chat; no process starts until the first message. Returns `{chat, events}` like `chat_get`. |
| `chat_list` | `ref_id`. Returns `chats`, newest first: `id`, `ref_id`, `project_id`, `agent`, `agent_label`, `title`, `created_at`, `updated_at`, `busy`, `status`, `resumable`, `model`, `effort`, `event_count`. |
| `chat_models` | `agent`. Returns `models` (`id`, `label`, `efforts`, `default_effort`) and `default` (`model`, `effort`: what the agent uses without a choice, when its config says). Codex's come from `codex debug models` (listed models only, in Codex's order) and `config.toml`; Claude Code's are its aliases and `settings.json`'s `model`. Cached for ten minutes. |
| `chat_set_model` | `chat_id`, `model`, `effort` (null or empty for the default). Applies from the next message: Codex passes `-m` and `model_reasoning_effort`; a running Claude Code process started with other choices is restarted on the same session with `--model` and `--effort`. Returns `{chat_id, model, effort}`. |
| `chat_get` | `chat_id`; optional `after_seq`. Returns `chat` (as above, plus `draft`, the reply streaming right now, and `pending_approvals`) and stored `events` of `{seq, kind, data, created_at}`. |
| `chat_send` | `chat_id`, `text`; optional `selection` (`{page, text}`, sent as a quoted passage) and `clip` (`{page, rect_pt:{x,y,width,height}, source_pdf?}`, rendered from the reference's PDF and sent as an image). Refreshes the chat's context file, stores the `user` event and starts the turn; returns `{seq}`. One turn at a time per chat. |
| `chat_cancel` | `chat_id`. Interrupts the running turn (Claude Code: an interrupt request, Codex: SIGINT; either is stopped outright after 8 seconds) and denies pending approvals. |
| `chat_approve` | `chat_id`, `request_id`, `allow` (boolean). Answers a pending approval once. |
| `chat_delete` | `chat_id`. Stops its agent, denies pending approvals, deletes the chat, its events and its folder. |
| `chat_resume_command` | `chat_id`. Returns `argv`, `cwd` and `title` for continuing the session in a terminal (`claude --resume` / `codex resume`, with the chat's model and effort) with an MCP config that has no approval queue. Needs a started session. |
| `chat_permission_request` | `chat_id`, `tool`, `input`, `source`. Used by `omabib mcp` inside a chat: records an `approval` event and blocks until `chat_approve`, a cancel, or ten minutes (deny). Returns `{allow, message}`. |
| `chat_subscribe` | none. On this connection, pushes every chat event as a line `{"v":1,"event":"chat","chat_id","seq","kind","data"}` until the connection closes. |

Event kinds: `user`, `session` (agent, version, model), `assistant` (`text`), `tool_call` (`id`, `name`, `input` with long strings shortened), `tool_result` (`id`, `output` up to 4 KB, `is_error`), `approval` (`request_id`, `tool`, `input`, `source`), `approval_result` (`request_id`, `allow`, optional `reason`: `expired`, `cancelled`, `deleted`), `turn_end` (`interrupted`, `is_error`, `usage`, and for Claude Code `session_cost_usd`), `error` (`message`) and `note`. Pushed only, with `seq:null`: `delta` (`text`, the streaming reply) and `status` (`status`: `thinking`, `writing`, `tool`, `approval` or `idle`; `busy`).

When `omabib mcp` runs with `OMABIB_CHAT_ID` set, every tool with `readOnlyHint:false` except `get_pdf` and `get_alphaxiv_overview` first asks `chat_permission_request`; a denial returns a tool error and the write never runs. With `OMABIB_CHAT_AGENT=claude` it also offers `chat_permission`, Claude Code's `--permission-prompt-tool`, which answers `{"behavior":"allow","updatedInput":…}` or `{"behavior":"deny","message":…}` from the same queue. `delete_reference_preview` reports `chat_count`, and `delete_reference` returns the deleted `chats_deleted` IDs.
