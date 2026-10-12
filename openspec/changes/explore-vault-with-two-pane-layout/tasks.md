Each task is scoped to at most 15 minutes. Split a task further if implementation reveals additional work. Write and run the failing regression before each behavior change. Commit each passing, coherent slice with a conventional commit message.

## 1. Exact-folder metadata

- [x] 1.1 Add failing endpoint tests for exact folder, exact root, recursive default, and invalid boolean values.
- [x] 1.2 Parse `include_subfolders` and implement exact-path filtering before pagination.
- [x] 1.3 Add failing pagination and authorization tests with combined path, tag, and sort filters.
- [x] 1.4 Make filtered pagination and authorization tests pass and commit the API slice.
- [x] 1.5 Add failing API-client tests for exact-folder requests, file metadata parsing, and retained file counts.
- [x] 1.6 Implement the client metadata methods and models, verify tests, and commit.

## 2. Tree contents and cache

- [x] 2.1 Add failing controller tests for lazy expansion, direct contents, deduplication, and note page loading.
- [x] 2.2 Implement per-folder metadata loading and note cursors.
- [x] 2.3 Add failing tests for collapse/reopen caching, per-folder errors, retry, and stale responses after vault switching.
- [x] 2.4 Implement cache lifecycle, retry, and request invalidation.
- [x] 2.5 Add failing tests for moved/deleted/renamed notes and successful local upload or folder creation.
- [x] 2.6 Implement event invalidation and local refresh hooks, run controller tests, and commit.

## 3. Tree interaction

- [x] 3.1 Add failing widget tests for independent folder selection and expansion, root items, empty folders, and file-only folders.
- [x] 3.2 Render mixed folder and document rows with deterministic ordering.
- [x] 3.3 Add loading, error, retry, and Load more rows and verify their interactions.
- [x] 3.4 Add failing keyboard and semantics tests for traversal, collapse/expand, activation, and selected state.
- [x] 3.5 Implement keyboard and accessibility behavior, run tree tests, and commit.

## 4. Main destinations and navigation

- [x] 4.1 Add failing route tests for folder selection, explicit root scope, note URLs, and file destinations.
- [x] 4.2 Implement folder and file route state while preserving note edit-mode and database routes.
- [x] 4.3 Add failing overview tests for direct child folders, notes, files, breadcrumbs, and creation/upload actions.
- [x] 4.4 Build the folder overview using shared tree metadata and the existing actions.
- [x] 4.5 Add failing return-navigation tests for filtered, multi-page list and overview scroll restoration and no-history fallback.
- [x] 4.6 Implement browse snapshots and document return behavior.
- [x] 4.7 Add failing navigation tests for save failure or cancellation when selecting notes, files, folders, databases, breadcrumbs, or vaults.
- [x] 4.8 Route departures and vault switching through the edit guard before changing configuration, and defer selection changes until success.
- [x] 4.9 Add failing tests for revealing notes from search and deep links, including a note on a later page.
- [x] 4.10 Implement ancestor expansion, row reveal, and active-document highlighting; run navigation tests and commit.

## 5. File viewing

- [x] 5.1 Add failing authenticated file-access tests for encoded paths, missing files, and access denial.
- [x] 5.2 Implement file fetching without exposing credentials in URLs.
- [x] 5.3 Add failing view tests for image preview, oversized-image fallback, other-file details, and retry.
- [x] 5.4 Implement bounded image preview and file details states.
- [x] 5.5 Add failing download-action tests using a fake platform save destination.
- [x] 5.6 Implement explicit authenticated downloads, run file tests, and commit.

## 6. Two-pane desktop shell

- [x] 6.1 Add failing shell tests for two panes at 840, 1000, and 1200 logical pixels and stacked navigation at 839.
- [x] 6.2 Replace the permanent middle pane with the routed main area at the expanded breakpoint.
- [x] 6.3 Replace the desktop root placeholder with the selected overview or All notes list.
- [x] 6.4 Add failing tests for a dirty draft across resize, persisted sidebar width, and accessible resize actions.
- [x] 6.5 Preserve editor state across the breakpoint and clamp sidebar width for the available space.
- [x] 6.6 Verify search overlay, database navigation, knowledge proposals, settings, creation, and upload remain reachable.
- [x] 6.7 Remove obsolete three-pane constants and descriptions, run shell tests, and commit.

## 7. Definition of Done

- [x] 7.1 Run relevant Dart formatting, analyzer checks, and server and Flutter regression tests.
- [x] 7.2 Follow the project-local verification skill with an isolated vault containing root items, nested notes, files, and an empty folder.
- [x] 7.3 Verify desktop browsing, file preview/download, deep links, and compact navigation against the isolated server; verify guarded departures and keyboard use through widget regressions.
- [x] 7.4 Verify later-page loading and live note updates against the isolated server; verify local upload refresh through the fixture-picker regression.
- [x] 7.5 Reconcile overlapping empty-folder, upload, workspace, and search deltas before spec synchronization.
- [x] 7.6 Run strict OpenSpec validation and commit the final verified slice with a conventional commit message.
