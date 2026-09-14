# Omabib history

Private, portable history of Omabib bibliographic metadata and contextual notes, with Git LFS storage for PDFs. SQLite remains the working database. The live database and search indexes are not committed.

## Save changes

On the configured desktop:

```bash
omabib-history             # export changed metadata and create a local commit
omabib-history --push      # export, commit, and push to GitHub
```

Or run `python3 tools/snapshot.py --db /absolute/path/library.db --push` from a clone. Git LFS must be installed and initialized with `git lfs install --local`.

Snapshots are explicit. There is no scheduled export, background push, automatic pull, or two-way synchronization. The command refuses to overwrite locally edited generated metadata or include unrelated staged work. Search never waits for Git.

## Contents

- `metadata/references/<UUID>.json`: citation keys, BibTeX, parsed fields, provenance and timestamps.
- `metadata/projects/<UUID>.json`: projects, descriptions and registered roots.
- `metadata/associations.json`: project/reference relationships and labels.
- `notes/<UUID>.md`: note body plus exact structured metadata in JSON-compatible YAML front matter.
- `metadata/note-revisions/<UUID>.json`: existing note revision history.
- `metadata/attachments/<UUID>.json`: reference associations, original local paths, archived PDF paths and checksums.
- `pdfs/`: LFS-managed PDFs, deduplicated by content when copied from linked attachments.

An export reads all metadata in one SQLite read transaction, closes it, then writes files and copies linked PDFs. A PDF copy represents the bytes read during that copy, independently of the metadata snapshot. Unavailable originals retain their last archived pointer when available. Other attachment types retain metadata only.

This is a portable history export, not a complete SQLite backup or an implemented restore/sync engine. Keep using `omabib backup` for exact database recovery.
