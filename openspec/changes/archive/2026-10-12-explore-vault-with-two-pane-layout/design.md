## Context

See proposal.md for the motivation. `app_router.dart` currently mounts a persistent folder sidebar, a fixed-width `NotesListScreen`, and a routed detail pane at 1200 logical pixels. `Breakpoints.expanded` starts at 840. Smaller layouts already support stacked navigation. Sidebar width persists through app preferences.

`FolderTreeController` currently loads folder hierarchy and subscribes to note changes. `GET /notes/tree` already includes empty-folder markers and file counts, although the client model only retains note counts. `GET /notes/files?path=` returns direct file metadata, and `GET /notes/files/{path}` serves authenticated bytes. `GET /notes?path=` includes descendants, so it cannot directly populate immediate tree children. `NoteNavigationRegistry` already guards route departures with pending-edit handling.

The main specs lag some implemented behavior. In particular, completed changes cover empty folders and the search overlay, while `add-file-upload` remains unfinished despite existing server file routes. This proposal uses the implemented endpoints without claiming the entire upload change is complete. Before archive, sync completed foundational changes first and apply this delta last. This delta retains empty-folder creation scenarios, supersedes folder selection as recursive list scoping, and replaces the earlier three-pane layout. Upload actions and the existing search overlay remain supported.

## Goals / Non-Goals

**Goals:** Keep one navigation tree mounted while the main destination changes, reuse existing metadata contracts, and route every document departure through the same edit guard.

**Non-Goals:** No full-vault document preload, storage migration, general file editor, PDF rendering dependency, or new background file notification protocol.

## Decisions

### Use one desktop shell from 840 logical pixels

Replace the three-pane branch with a tree and a routed main area at `Breakpoints.expanded` and above. Retain the saved sidebar width and clamp it so the main area remains usable at the boundary. Keep the existing compact and stacked layouts below that boundary. Retaining the 1200 threshold would leave typical desktop windows without persistent document navigation even though removing the middle pane frees enough width.

The `/` destination becomes a real overview or All notes list instead of an empty detail placeholder. Folder selection navigates to `/` with a URL-encoded folder query parameter, including an explicit empty value for vault root. Add a file destination with its vault-relative path encoded as a query parameter. Keep `/notes/:id`, edit-mode parameters, and database routes compatible. Search remains an overlay.

### Reuse metadata endpoints with an additive exact-folder filter

Extend the server list query and API client with `include_subfolders`, defaulting to true. Tree requests use `path` plus false. Apply this filter before pagination rather than filtering recursive pages in the client. Client-side filtering could miss direct notes and require scanning whole subtrees.

Retain `file_count` in the tree model. Fetch direct files through the existing endpoint. That endpoint currently returns all direct file metadata, so file pagination is deferred. Note pages remain bounded by the existing API limit and expose Load more. Sort accumulated document entries by display label, with stable identity ties. Ordering is alphabetical among loaded pages, not a promise that unseen pages follow alphabetically. A label-sorted API is outside this change.

### Cache folder contents within the vault session

Extend the tree controller with expanded paths, per-folder notes, files, note cursors, loading state, and errors. Deduplicate entries by note ID or full relative file path. Preserve loaded contents across collapse. Ignore responses from superseded requests and previous vault sessions.

Use existing note events to invalidate affected folders. If a move event lacks the old path, invalidate all loaded folders rather than leaving a stale duplicate. Title updates refresh loaded metadata. Local uploads and folder creation explicitly invalidate their folders; an explicit refresh covers external file changes. No remote file event support is assumed.

Fetch root metadata as the tree's initial visible folder. Keep root documents separate from All notes, which remains an aggregate view. Keep existing database, knowledge proposal, settings, and creation entry points accessible.

### Represent the active destination independently of browse context

Maintain a session-scoped browse snapshot containing folder or All notes scope, filters, sort, pagination, and scroll offset. Tree selection derives from the active destination. A folder overview includes direct child folders and shares document metadata with the tree; All notes reuses the existing list behavior.

All notes initialization must retain loaded pages when restoring browse state instead of refreshing on every mount. Opening a note or file replaces the main destination. Closing returns to the snapshot or All notes when none exists. A note fetched through a deep link provides its folder path for ancestor expansion. Follow metadata pages until its ID appears and scroll to its row. Persist neither browse snapshots nor document caches across vault changes.

Reuse `NoteNavigationRegistry` for folder, file, database, breadcrumb, note selection, and vault switching. Guard a vault switch against the old session before persisting the new vault ID. Commit selection and browse changes only after navigation succeeds. Expanding a chevron does not leave the document and therefore does not trigger a save.

### Provide bounded file viewing

Add client metadata and authenticated byte-fetch support. Preview images inline, subject to a bounded size supported by the client. Oversized images and other formats use file details and an explicit download action. Route errors stay in the main area with retry and return actions. Avoid embedding arbitrary remote HTML or placing credentials in download URLs. Use the existing authenticated transport and platform save mechanism.

Tree rows expose separate selection and expansion semantics. Provide keyboard traversal, left/right collapse and expansion, Enter activation, visible focus, and accessible selected/expanded state. Flatten visible rows for rendering so unopened descendants do not build document widgets.

## Risks / Trade-offs

- Large direct file lists or a late-page deep-linked note can require substantial metadata. Lazy folder loading and bounded note pages limit ordinary browsing. Keep loading visible and permit cancellation when the destination changes.
- Removing the permanent list also removes its toolbar from document screens. Keep search, create, upload, and account actions reachable from shell controls or existing menus.
- Switching presentation at 840 can remount the editor. Preserve controller ownership and exercise a dirty draft across the boundary.
- Pending specs can conflict at archive. Compare the tree delta with empty-folder and file-upload work, and reconcile workspace and search deltas before syncing.

## Migration Plan

Ship the additive API filter first, then the client metadata/cache changes, followed by the tree and desktop shell. No data migration is needed. Test against the updated server; older servers that ignore the filter must not silently produce a recursive tree. Validate returned paths and show a compatibility error when an exact-folder contract cannot be satisfied.

Rollback the client shell and tree changes together if navigation regressions appear. The additive API parameter can remain because existing clients retain recursive defaults.
