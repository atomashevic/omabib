# JSON interface

All operations use `omabib call METHOD` with one JSON object on stdin. The socket protocol is newline-delimited JSON:

```json
{"v":1,"id":1,"method":"search","params":{"query":"network","limit":8}}
```

A response echoes `v` and `id`, with either `result` or `error.message`. Search requests on one connection supersede earlier searches. `cancel` cancels that connection's active search generation. SQL progress handlers interrupt superseded work. Clients must discard stale results as well.

## Search and reading

| Method | Parameters |
|---|---|
| `search` | `query`; optional `project_id`, `include_other_projects`, `limit` (1–25), `cursor`, `author`, `year` (string), `entry_type`, `project_filter`, `label` |
| `get_reference` | `id` (UUID or citation key); optional `include_metadata` (default true), `include_notes`, `include_attachments`, `project_id`, `include_other_projects`, `note_limit`, `note_cursor`, `note_chars`, `include_history` |
| `project_context` | `project_id`; optional `query`, `cursor`, `max_chars` (1,000–32,000; default 8,000) |
| `list_projects` | optional `cwd`; returns all projects and longest-root resolution, or explicit ambiguity |
| `status` | none |

Search metadata is compact; a note match includes its project identity. The `ranking` field names the bounded scoring strategy. Broad candidate sets are identified by `candidate_limited`. Refine a query rather than assuming every matching record is present in that ranked selection.

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
| `create_project` | `name`; optional `description`, absolute `roots` array |
| `update_project` | `id`, `name`, `description`, `roots`; replaces these project fields |
| `associate` | `ref_id`, `project_id`, optional `labels`; replaces the association's labels |
| `attach` | `ref_id`, absolute `path`; optional `file_type` (default pdf), `fingerprint` |

Import results include `repairs`, `duplicates_merged`, and one `items` entry per resulting reference. Repeated citation keys within the input and identical input entries consolidate automatically, filling missing fields and reporting conflicting values; distinct DOIs prevent merging. Unambiguous missing field commas and repeated fields are repaired. Original import text is retained.

Imports are transactional. Known DOI identity and compatible citation-key records are reused; missing fields are filled, conflicting values are reported and preserved. Distinct identifiers do not merge just because keys collide. Renamed incoming cross-reference keys are adjusted. Missing dependencies make bibliography export fail explicitly.

Attachments are pointers, not file copies. Missing paths remain visible and can be relinked by adding a corrected path. No fingerprint is calculated implicitly.

## Notes

`add_note` requires `ref_id`, explicit `project_id` (UUID or null), `body` and `provenance`. Optional `labels` is an array of strings; `evidence` is a string. `update_note` requires the note `id` and `expected_revision` instead of a new reference ID. Updates preserve the previous snapshot in `note_revisions` and cannot silently overwrite a later revision.

Supply all note fields being retained when updating. Note bodies are limited to 64 KiB. Use `idempotency_key` for retried writes; MCP requires that parameter. Adding a project-specific note also associates the reference with that project.

## Export and backup

- `export_bibtex`: `ids` or `project_id`; includes crossref/xref/xdata dependencies and returns `bibtex` plus `count`.
- `export_notes`: `ids` or `project_id`, optional `include_other_projects`; returns Markdown with reference, project, provenance, evidence and note/revision identifiers.
- `backup`: a new destination `path`; never overwrites an existing file.

For large exports, redirect CLI output to a file rather than loading it into an agent conversation. Public interfaces operate on stable UUIDs; citation keys remain convenient human-facing selectors.

## Repository and PDF operations

| Operation | Parameters and behavior |
|---|---|
| `get_repo_config` | Returns `repo_path`, `remote_url`, `branch`, and `configured`. |
| `set_repo_config` | Required `repo_path`, `remote_url`, `branch`. Selects an existing LFS-enabled checkout and updates its origin. Superseded by `repo_setup`'s `local` mode, which also checks and can fix prerequisites; kept for existing callers. |
| `repo_check` | Optional `repo_path`. Read-only: reports whether `git`, `git-lfs` and `gh` are installed, whether `gh` is logged in (and as whom), whether a global Git identity is set, and — when `repo_path` is given — that path's state: `missing`\|`empty`\|`not_a_directory`\|`not_a_repo`\|`repo`, plus (for `repo`) `lfs_tracked`, `branch`, `origin`, `dirty`, `commits`, `is_omabib_history`. |
| `repo_setup` | `mode:"create_github"` (`name`, optional `repo_path`, `branch`) scaffolds a new checkout from Omabib's templates and creates a private GitHub repository via `gh`. `mode:"local"` (`repo_path`, `branch`, optional `remote_url`, `fix_lfs`) adopts an existing checkout, running `git lfs install --local` and adding `.gitattributes`/`.gitignore` entries when `fix_lfs` is set and PDFs aren't tracked yet. Both save the resulting configuration, same shape as `get_repo_config`. |
| `repo_status` | Optional `fetch` (runs `git fetch` first). Read-only and safe to poll. Returns configuration, `head` (`hash`, `subject`, `date`), `ahead`/`behind` the remote, `dirty` (local edits in the directories a sync manages), `pending` (new/edited reference and note counts since the last successful sync), and the last sync attempt's `last_attempt`/`last_success` (timestamps) and `last_result`/`last_error` (`{kind, message, hint}`; see below). |
| `sync_repo` | Optional `push` (default true). Exports a snapshot, commits changed generated data, optionally pushes. Result: `references`/`notes`/`projects`/`archived_pdfs`/`missing_pdf_ids` (as before), plus `committed`, `changed_files`, `commit`, and — when pushed — `pushed`, `commits_pushed`. A push that fails *after* a successful local commit returns `ok:false`, `committed:true` and `push_error` instead of raising, so the commit is never lost; retry the sync (or resolve what `push_error` describes) once the underlying problem is fixed. |
| `get_pdf` | `ref_id`; optional `download` (default true). Returns a locally readable `path` to a PDF: an existing attachment (`source:"local"`), one restored from the history repository's Git LFS archive (`"history"`), or (unless `download:false`) a freshly downloaded open-access copy — from the reference's own `pdf` field, an arXiv direct link, OpenAlex, or Semantic Scholar — which is attached in the process (`"downloaded"`). Returns a path, never PDF text. |
| `add_pdf` | Required `ref_id` (UUID or citation key), absolute `path`; optional `idempotency_key`. Returns the stable attachment `id`, reference ID and path. |
| `pull_pdf` | Either `attachment_id` for Git LFS recovery, or `ref_id` and HTTPS `url` for a download. Optional `idempotency_key` for URL attachment writes. Returns attachment ID/path. |
| `remove_pdf` | Required `attachment_id`, optional `idempotency_key`. Unlinks only; `file_deleted` is false. |
| `get_attachment` | CLI-only lookup by attachment `id`. |

`add_pdf`, `pull_pdf`, `remove_pdf` and `get_pdf` are also MCP tools. Use `get_reference` with `include_attachments:true` to discover attachment IDs, or its always-present `pdf_path` when only a path is needed. Managed PDFs (downloaded, or restored from history) are stored as `pdfs/<citekey>.pdf`, with a short content-hash suffix only on a genuine name collision; the history repository itself keeps its own content-addressed `pdfs/<sha256>.pdf` naming, unrelated to the local one. Git LFS retrieval fetches remote objects without checking out remote metadata or overwriting the working tree. A pull preserves the attachment UUID and verifies the restored PDF against the archived SHA-256.

`repo_status`'s `last_error.kind` is one of: `diverged` (the remote has commits the checkout doesn't; Omabib never merges or force-pushes — pull, then sync again), `auth`, `network` (the commit was kept locally), `lfs`, `dirty` (edits in `metadata`/`notes` outside Omabib's control), `branch`, `origin-changed`, `busy`, or `unknown`. Each carries a human `hint`.

### Metadata and abstract enrichment, and opening

- `open_target {id}` resolves an existing PDF, HTTP(S) URL, or DOI URL, without launching it.
- `lookup_metadata {id}` returns up to five ranked online candidates with `fields`, `additions`, `conflicts`, `source`, `needs_abstract`, and (once found) `abstract_source`; top-level `id` and `expected_revision` identify the unchanged reference. For an identifier match (not a broad title search), a missing abstract and open-access PDF link are looked up automatically — trying the primary record (Crossref/DataCite), then OpenAlex, then Semantic Scholar, then Europe PMC — so a caller doesn't need a second round trip.
- `supplement_metadata {id, doi}` re-runs that same abstract lookup by exact DOI (or the DOI an arXiv ID infers into) for a selected candidate. Returns `fields`, `source`, `gateway` (which service supplied it, or `"none"`), and a `warning` when nothing was found. Never mixes in title-search results.
- `lookup_abstract {id}` previews an abstract for one reference that already has an exact DOI or arXiv identifier — the single-reference version of what `enrich --abstracts` loops over. Returns `abstract`, `source`, `expected_revision` (all `null`/absent-safe when nothing was found), without writing.
- `missing_abstracts` (CLI-only) lists references with no abstract yet (`id`, `citekey` pairs, optional `limit`, default/cap 5,000/20,000) plus a `total` count. Used by `enrich --abstracts` rather than a direct database read, so it always sees the exact database the service itself is writing to.
- `apply_metadata {id, expected_revision, fields, source, idempotency_key?}` fills only empty fields, keeps IDs/keys/notes/attachments, rejects stale revisions or DOI collisions, and updates the search index. Pass the reviewed candidate's additions and provenance. None of these operations is automatically invoked during search.

`omabib lookup REFERENCE` invokes `lookup_metadata`; `omabib enrich --abstracts [--limit N] [--dry-run]` loops `missing_abstracts` → `lookup_abstract` → `apply_metadata` across the library, about one request per second, resumable since already-filled references are skipped on a rerun. These operations are available through the JSON CLI; existing compact MCP tool discovery is unchanged (now 12 tools: the original 10 plus `get_pdf` and `add_reference`).
