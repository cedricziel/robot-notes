## Context

The app is Flutter with Riverpod, `go_router`, a single `RobotNotesClient`, one `WsClient`, and per-screen controllers (`NoteController`, `NotesListController`, `FolderTreeController`) that expose `ValueListenable` state. The note editor is a plain `TextField` with `MarkdownBody` (flutter_markdown_plus) in view mode. `NoteController` already listens to `ChangedEvent` for its note and refetches when not editing. See `../add-databases` for the server contract and `proposal.md` for what this adds.

## Goals / Non-Goals

**Goals:**

- Reuse the existing controller pattern and the shared DTOs; no new state-management dependency.
- Property edits never interfere with the body editor's lock, autosave, or `If-Match` baseline.
- Every new screen is URL-addressable like the existing ones.

**Non-Goals:**

- Local caching or offline queueing of property edits.
- Virtualised tables beyond what `ListView.builder` gives; homelab scale.
- Pixel parity with Notion.

## Decisions

**One `DatabaseController` per open database screen** holding the definition, the selected view, the row pages, the group counts, and an in-flight-patch map keyed by note id so optimistic updates can be reverted. It subscribes to wildcard `changed` events (the WS client already supports `*`) and debounces re-query to one per second. Alternative: derive rows from a global notes cache. Rejected: filters and sorts are server-side and the client would have to reimplement them.

**Cell editors are one widget family `PropertyEditor(type, value, onCommit)`** used by the table cell, the board card (read-only variant), the property panel, and the row-creation form. Each type maps to one widget: `text`/`url` → `TextField`, `number` → numeric `TextField` with parsing, `checkbox` → `Checkbox`, `date` → `showDatePicker` with an optional time toggle, `select` → `DropdownMenu`, `multi_select` → filter chips, `relation` → the existing `link_autocomplete` search reused as a picker producing `[[Title]]` strings. The editor commits a `PropertyPatch {set, unset}`; the caller sends it.

**Board drag uses Flutter's `LongPressDraggable`/`DragTarget`** with column-level targets. On drop the controller patches optimistically (moves the card in local state, sends `PATCH`, reverts on error). No reordering within a column (no server-side order property exists). Each column runs its own paged query with a filter override combining the view filter and the column's `eq`/`is_empty` condition, so large columns page independently and counts always match the server's `groups`.

**Property panel lives in `NoteController`** as a separate `properties`/`coveringDefinitions` slice of `NoteState`. `patchProperty` goes through the same write queue as body saves: it cancels an armed autosave, waits for an in-flight save, sends the patch, adopts the returned `version` as the `If-Match` baseline (safe because the server preserves the body byte-for-byte), and re-arms autosave. The `ChangedEvent` handler gains a branch: when editing, refetch `GET /notes/{id}` and copy only `properties` into state for display, never `version`, so a remote body edit still produces the 409 conflict view the existing spec mandates; when not editing, the existing full refresh applies. Covering definitions are found client-side with the `coveringDatabases` helper that `add-databases` adds to `shared` (folder prefix with `include_subfolders`, tag membership, definition excluded), fed by the cached full definitions from `GET /databases/{id}`; the server remains the authority on validation.

**Embeds are rendered by a custom `MarkdownBody` block syntax.** flutter_markdown_plus supports custom `BlockSyntax` + `MarkdownElementBuilder`; a syntax matches a whole line `^!\[\[(.+?)(#(.+?))?\]\]$` and emits an `embed` element rendered by `DatabaseEmbed(title, view)`, which maps the title to an id through `DatabasesController`'s list, fetches the cached full definition for view names, and reuses the table/board widgets in read-only mode with `limit: 50`. Inline `[[...]]` and non-matching text keep rendering literally, exactly as today (there is no wikilink rendering yet), so the block syntax must only claim whole lines. The embed is given a bounded height with its own scroll inside the reading column's `SingleChildScrollView`, and tap handlers are wrapped so they work inside the surrounding `SelectionArea`. The spike verifying the block-syntax API is the first task of the change, before anything is built on it. Alternative: preprocess the markdown string. Rejected: loses source positions and breaks selection.

**Schema editor is a full-screen form** driven by a local mutable copy of `DatabaseDefinition`; filters are edited with a small condition-list builder (property, op, value, and an and/or toggle at each nesting level, one level of nesting supported in the UI, deeper nesting displayed read-only as JSON). Save sends the whole `properties` and `views` sections, per the server's wholesale-replace semantics.

**Routing:** `GoRoute('/databases/:id')` inside the same `ShellRoute` as `/notes/:id`; the server's `static_web_middleware` dual-use path check gains `GET /databases/{id}` (not the bare list), with `Vary: Accept, Authorization`, tracked as a task here because it is client-serving behavior and as an `auth` spec delta.

**Sidebar:** `FolderTreeSidebar` gains a Databases section fed by a `DatabasesController` that fetches `GET /databases` and refreshes on any `changed` event with a 1 s debounce (cheap call, avoids tracking which notes are definitions).

## Risks / Trade-offs

- [Risk] flutter_markdown_plus custom block syntax API may differ across versions → Mitigation: spike task first; fall back to a line-splitting pre-pass that renders embeds as separate widgets between `MarkdownBody` segments.
- [Risk] Wildcard `changed` subscription on the database screen causes frequent re-queries in busy vaults → Mitigation: 1 s debounce and only re-query while the screen is mounted.
- [Risk] Client-side covering-database detection drifts from the server rule → Mitigation: both sides call the `coveringDatabases` helper in `shared` that `add-databases` introduces; the client treats it as best-effort for choosing editors and the server rejects anything invalid.
- [Risk] A 409 from `PUT /databases/{id}` has no `current` note in its body and the client's error mapper would surface it as a generic server error → Mitigation: extend the mapper so `version_conflict` without `current` becomes a `VersionConflictException` with a null `current`.
- [Trade-off] Board has no manual ordering → accepted; rows sort by the view's sort.
- [Trade-off] Filter editor supports one nesting level → accepted; deeper filters remain editable via MCP or by hand.
