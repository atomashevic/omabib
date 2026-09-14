# Verification: Omabib 0.1.0

Measured on 2026-09-13 on this Omarchy desktop: AMD Ryzen 5 5500U, 12 logical CPUs, Quickshell 0.3.1, Rust 1.98.1, 1920×1080 display at approximately 60 Hz and 1.25 scale. The desktop remained in normal use during testing.

## Performance

The scale fixture began with 100,000 references and 300,000 notes. Repeated import checks added records: the final backend benchmark began with 101,010 references and ended with 102,010. UI measurements used that resulting library. Fixture text combines 20 research topics, 10 methods and 10,000 author identities with synthetic abstracts and contextual notes. This establishes scale behavior, not real-library relevance.

| Measurement | Result | Initial target |
|---|---:|---:|
| Warm backend query p95, range across 11 queries | 3.2–18.5 ms | ≤25 ms |
| Ordinary query change to rendered frame, p95 | 46 ms | ≤50 ms |
| Typo query change to rendered frame, p95 | 30 ms | ≤100 ms |
| Warm popup open to rendered frame, p95 | 36 ms | ≤100 ms |
| First popup after shell restart, one observation | 60 ms | Not a login benchmark |
| Service socket ready, including process launch | 101 ms | No separate target |
| Import 1,000 new references through public API | 2.01 s | No separate target |
| Search during import, wall p95 | 17.7 ms | No separate target |
| 44 queries across four concurrent readers | 167 ms total | No separate target |
| Resident service memory before import | 73 MiB | No separate target |
| Database file after fixture creation | 1.46 GiB | No separate target |
| Synthetic seed plus full index construction | 126.6 s | No separate target |

The seed uses bulk SQL followed by index rebuilds. It is not the public BibTeX importer. Import throughput is measured separately with 1,000 previously unseen citation keys and includes vocabulary refresh.

The UI uses `QQuickWindow.frameSwapped` to measure a rendered frame after the result model changes. Twenty ordinary queries, twenty typo queries and twenty window openings were measured. Query changes were sent through a diagnostic IPC method into the normal search-field property and debounce path. Physical keyboard delivery and monitor scanout are outside that measurement. The external command/poll harness observed readiness at 103 ms p95, which includes CLI startup and polling overhead.

First opening immediately after login was not tested because that would require interrupting the user's session. A single opening after restarting the shell measured 60 ms; it is not a substitute for a cold-login acceptance test.

Raw results: [backend](verification/backend.json), [rendered UI](verification/ui-timing.json), [keyboard smoke test](verification/keyboard.json).

## Correctness checks completed

`cargo test --locked`: eight behavioral tests pass. `cargo clippy --all-targets -- -D warnings`: clean. Release build succeeds.

The tests cover accent/LaTeX normalization, prefixes, substrings, one-edit transpositions, mixed-field and abstract matches, phrases and malformed punctuation; BibTeX macros, corporate authors, books, unknown fields and dependent exports; title capitalization and journal field export; DOI and citation-key collisions; note scope, cross-project opt-in, revisions and duplicate retry protection; ambiguous project roots, bounded context and missing attachment paths.

Live DOI lookups also passed, including a record with a spelled-out month. An existing title conflict appeared in the preview without changing the stored metadata.

Two real DOI records are checked in under `tests/fixtures/networks.bib`. Curated author/title searches find their intended record first. This small fixture does not establish recall or ranking quality on a diverse personal library.

`scripts/test_transport.py` passes against the release executable. It checks actual concurrent socket writes, one successful update in a stale-revision race, duplicate-service rejection, MCP initialization/discovery/search, backup and CLI restore preserving IDs and note history, refusal to overwrite a restore target, private restored-file permissions, and recovery after killing the service during an import with uncommitted WAL writes. Previously committed notes survive and none of the interrupted import's references appear.

Live keyboard checks passed for initial focus, result search, Tab details, Ctrl+K actions, Escape dismissal and Enter citation copying. A note was also saved through the editor, although concurrent desktop typing made its exact-text test inconclusive. Backend note persistence and conflict tests pass independently. The final popup was visually inspected using the current Omarchy theme. A full keyboard traversal of every dialog and live switching between themes remain manual acceptance checks.

The installed plugin validates, the user service is enabled and active, Codex's local stdio MCP registration is present, and Hyprland reports no configuration errors. Super+B is registered for Omabib. The production library contains no benchmark or test records.

## Design limits

Search ranks a bounded indexed candidate set with a separate title/author/key pass. It does not exhaustively sort every possible match. Broad queries may require narrowing, which the UI indicates. Lexical and typo retrieval do not provide conceptual similarity.

Automatic duplicate identity uses DOI and compatible citation keys. Other identifiers are retained and searchable; arbitrary identifier-based record merging is not implemented. Existing conflicting metadata remains unchanged and is reported for explicit editing.

Schema 1 is the initial format. There is no older released schema to migrate. Newer schema versions are rejected; future upgrade migrations must make a backup before modifying an existing library.

Cloud ChatGPT connectivity, automatic multi-computer metadata merging, full-PDF indexing, semantic embeddings and PDF reading/annotation remain outside v1. Explicit Git history export and PDF download/recovery are supported.

![Omabib with the isolated real-reference fixture](verification/popup.png)

## Numbered actions and bar integration

The follow-up UI adds actions 1–14, a themed in-popup BibTeX file browser, and a book icon containing the Omarchy glyph in the left bar. Live checks verified one- and two-digit shortcuts, file-browser cancellation, and importing a filename containing spaces into an isolated library. The initial Qt native chooser crashed Quickshell and was replaced by the in-popup browser. The final implementation imported successfully without restarting the shell. The normal library remained empty. See [UI action checks](verification/ui-actions.json).

## Automatic import repairs

Eleven library tests pass after adding duplicate-key consolidation, identical-entry consolidation, duplicate-field repair, missing-field-comma repair and BOM handling. Tests verify combining complementary metadata, conflict reporting, preservation of notes on reimport, distinct DOI separation, and avoiding incorrect merges when an incoming key collides with an existing reference. Malformed unclosed entries still fail atomically. Clippy is clean and the socket/MCP, backup and interrupted-import regression suite passes with the release build.


## Repository sync and PDF attachments

Twelve library tests pass, and Clippy is clean. The isolated history integration test verifies repository configuration, snapshot/push, PDF LFS pointers, recovery after deleting both the original PDF and local LFS object cache, attachment removal preserving the file, actual MCP attachment creation, HTTPS PDF download, and refusal to overwrite edited history metadata. The transport, revision, retry, backup and interrupted-import regression suite passes.

The installed interface was checked with real keyboard input. Action 16 opens populated repository settings; action 15 completes the configured GitHub push. Action 9 opens the PDF browser, and a filename containing spaces attaches successfully to the selected reference and appears in its refreshed detail view. Test attachments were confined to a temporary library. Repository and detail layouts were visually inspected.

The production sync reports 1,583 references, zero notes, zero archived PDFs, an unchanged commit and a successful push. The checkout is clean with zero divergence from origin/main. The service is active. Sync exports and pushes local metadata; it does not merge remote metadata into SQLite. Existing MCP sessions need reconnection to discover the three new PDF tools.

## Enter targets and online metadata

Seventeen tests pass (15 library tests and two provider/ranking unit tests), with clean Clippy. New checks cover PDF/URL/DOI target priority, missing attachment fallback, missing target errors, revision-safe and retry-safe enrichment, unchanged notes/keys/existing fields, BibTeX serialization, immediately searchable filled abstracts, provider mapping and original-paper ranking above commentary.

Live isolated gateway checks pass for Crossref DOI lookup, title-only DOI discovery, DataCite arXiv lookup and Europe PMC abstract supplementation. The returned abstracts contained 716, 1,276 and 1,136 characters for the three fixture references. Tests apply metadata only to temporary libraries.

Installed desktop checks pass for action 17, preview display, Ctrl+Enter application and Enter opening the reference link and dismissing the popup. Existing key copying is retained as action 1. The production library was not enriched during testing. Online retrieval is an explicit operation, and title-search candidates require review.

The final plain-text preview was visually verified after constraining its scroll viewport; long abstracts no longer paint over the title or action buttons. Production status remains 1,583 references and zero notes, with the service active.
