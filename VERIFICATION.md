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

## Magic add, abstract enrichment, storage wizard, sync status, and PDF access

Thirty-four tests pass: 12 unit tests (`abstracts`, `ingest`, `attachments`, `metadata`) and 22 library integration tests, with clean Clippy. New unit tests cover arXiv ID recognition (new/old/URL/`arXiv:` forms), DOI recognition, identifier splitting, `family_word_year` citation keys, the abstract chain's OpenAlex/Semantic Scholar/Europe PMC parsing and longest-wins/stop-at-threshold logic, PDF-URL scheme rejection, and PDF filename sanitizing. New library tests cover `pdf_path`/`has_pdf`/`has_abstract` reflecting attachments and abstracts correctly, `get_pdf` returning a local attachment without network and refusing when none exists and downloads are disabled, and `add_reference` end-to-end from BibTeX: attaching a PDF and linking a project inside one transaction, idempotent retry returning the identical cached result, rejecting a reused key with different content, requiring `input` or `pdf_path`, and — checked directly — writing nothing at all when attaching an unreadable `pdf_path` fails partway through.

`scripts/test_transport.py` and the extended `scripts/test_history_integration.py` pass against an isolated service and a local bare Git remote. New checks cover `repo_check` reporting installed tools and a candidate path's state (including missing Git LFS tracking) without a repository configured; `repo_setup`'s `local` mode refusing a checkout without LFS tracking until `fix_lfs` is set, then configuring it; `repo_status` reporting configuration, zero ahead/behind, and pending changes appearing after a note is added post-sync; and a genuinely diverged remote (a second clone pushes first) causing `sync_repo` to return `ok:false` with the local commit still made (`committed:true`) and `repo_status().last_error.kind` reporting `"diverged"`.

Live, network-dependent checks (temporary libraries only) verified: `add_reference` for an arXiv ID fetched an abstract and downloaded a citekey-named PDF (`vaswani_attention_2017.pdf`, confirmed to start with `%PDF-`); `add_reference` for an Elsevier DOI (`10.1016/j.chbah.2026.100296`) filled an abstract via OpenAlex, which Crossref and DataCite do not carry for it; retrying the same `idempotency_key` returned the identical cached result; a URL with no DOI/arXiv pattern in the URL string itself (a Frontiers article page) still resolved, through either an inferred DOI or the page's own `citation_*` metadata; a comma-separated multi-identifier paste (`preview_entry`) produced one item per identifier, correctly typed; `get_pdf` returned the just-downloaded local copy without a new request, and `identify_pdf` on that same file found a DOI/arXiv-ID pattern or (title-search fallback) a title containing "Attention"; the stdio MCP adapter's `tools/list` reported exactly 12 tools including `add_reference` and `get_pdf`, and both worked through `tools/call`; `omabib enrich --abstracts --limit 3` against three freshly imported DOI-only references filled 2 of 3 (via Semantic Scholar and OpenAlex; the third had no abstract available anywhere checked), matching abstract availability independently confirmed for those DOIs via direct API calls beforehand.

An earlier version of the abstract-enrichment code left `abstract_source` unset whenever Crossref or DataCite's own record already carried the abstract (only setting it when the separate OpenAlex/Semantic Scholar/Europe PMC chain had to add one) — caught by the arXiv `add_reference` check above, since DataCite supplies that paper's abstract directly. Fixed so the primary gateway is reported as the source in that case too.

An earlier version of `omabib enrich` listed references missing an abstract via a direct SQLite read at a guessed path (`OMABIB_DB`, defaulting to the production library) rather than through the running service's own connection, so an isolated test service reachable only via `OMABIB_SOCKET` could silently list a different library than the one its RPC calls then operated on. Caught because the backfill filled zero of three references it should have filled in an isolated test. **The production library was not affected**: checked directly afterward — still exactly 1,584 references, and the most recently `updated_at` timestamp across all references was from 2026-09-13, before this change was made, with nothing from the day of this fix. The RPC calls in the failing run simply errored ("reference not found") against the mismatched database rather than writing anywhere. Fixed with a new `missing_abstracts` service-side operation that always lists from the exact database the service itself is running.

`omarchy plugin validate plugin` passes. `qmllint` was tried against the modified `plugin/App.qml`; its output (a silent non-zero exit) was identical before and after this round of changes, which also reproduces on the pre-existing unmodified file, so it reflects a limitation of running `qmllint` on a Quickshell-dependent file outside a Quickshell environment, not a defect introduced here. A brace/paren/bracket balance check and manual review of the diff found no imbalance or obvious error. The updated UI (search-field magic add, quick-add preview showing abstract/PDF status per item and calling `add_reference` for a single recognized identifier, the sync status chip, the repository setup dialog's live prerequisite checks and two setup paths, and the Get PDF/Copy PDF path actions) has **not** been exercised with live keyboard input against the running desktop this round — doing so would take over the user's keyboard via `wtype`, which needs their go-ahead first (as `scripts/test_ui.py` itself already notes, "should run while no one else is typing").

The production library was not modified during any of this round's testing: reference count checked at 1,584 both before this work began and after it concluded, and no `updated_at` timestamp from today was found.
