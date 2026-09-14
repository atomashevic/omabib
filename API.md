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

`get_reference` returns source field values and a normalized editable BibTeX-family representation. Notes are opt-in. `include_history` explicitly asks for prior revisions and is CLI-only. Full original import text is retained in the database.

## Metadata and project writes

| Method | Parameters |
|---|---|
| `import_bibtex` | `bibtex` (up to 64 MiB), optional `source`, `idempotency_key` |
| `upsert_reference` | one-entry `bibtex`; for edits, `id` and `expected_revision`; optional `source`, `idempotency_key` |
| `preview_doi` | `doi`; returns BibTeX, current conflicts, proposed citation keys and `saved:false`; pass the result to `import_bibtex` only when saving is intended |
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
| `set_repo_config` | Required `repo_path`, `remote_url`, `branch`. Selects an existing LFS-enabled checkout and updates its origin. |
| `sync_repo` | Optional `push` (default true). Exports a snapshot, commits changed generated data, optionally pushes. |
| `add_pdf` | Required `ref_id` (UUID or citation key), absolute `path`; optional `idempotency_key`. Returns the stable attachment `id`, reference ID and path. |
| `pull_pdf` | Either `attachment_id` for Git LFS recovery, or `ref_id` and HTTPS `url` for a download. Optional `idempotency_key` for URL attachment writes. Returns attachment ID/path. |
| `remove_pdf` | Required `attachment_id`, optional `idempotency_key`. Unlinks only; `file_deleted` is false. |
| `get_attachment` | CLI-only lookup by attachment `id`. |

The three PDF operations are also MCP tools. Use `get_reference` with `include_attachments:true` to discover IDs. Repository sync and settings are CLI/UI operations. Git LFS retrieval fetches remote objects without checking out remote metadata or overwriting the working tree. A pull preserves the attachment UUID and verifies the restored PDF against the archived SHA-256.

### Metadata enrichment and opening

- `open_target {id}` resolves an existing PDF, HTTP(S) URL, or DOI URL, without launching it.
- `lookup_metadata {id}` returns up to five ranked online candidates with `fields`, `additions`, `conflicts`, `source`, and `needs_abstract`; top-level `id` and `expected_revision` identify the unchanged reference.
- `supplement_metadata {id, doi}` returns additional abstract metadata from Europe PMC by exact DOI. Unavailable services return a warning without changing the library.
- `apply_metadata {id, expected_revision, fields, source, idempotency_key?}` fills only empty fields, keeps IDs/keys/notes/attachments, rejects stale revisions or DOI collisions, and updates the search index. Pass the reviewed candidate's additions and provenance. None of these operations is automatically invoked during search.

The `omabib lookup REFERENCE` convenience command invokes `lookup_metadata`. These operations are available through the JSON CLI; existing compact MCP tool discovery is unchanged.
