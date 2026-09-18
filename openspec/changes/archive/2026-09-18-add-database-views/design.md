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

**Embeds are rendered by a custom `MarkdownBody` block syntax — confirmed by the task-1.1 spike (`app/test/src/databases/database_embed_syntax_spike_test.dart`, `app/lib/src/databases/database_embed_syntax.dart`).** flutter_markdown_plus (backed by `package:markdown`) does support this API shape exactly as hoped, with no fallback needed:

- Subclass `md.BlockSyntax` (from `package:markdown`, re-exported through `flutter_markdown_plus`'s dependency, so `markdown` must be added as a direct `app` dependency to reference `md.Element`/`md.BlockParser`/`md.Node` by name). Override `RegExp get pattern` and `md.Node? parse(md.BlockParser parser)`. The regex must be **anchored start-to-end** (`^!\[\[(.+?)(?:#(.+?))?\]\]\s*$`) — an unanchored pattern would also match the embed syntax when it appears mid-paragraph, which is exactly the behavior the design forbids. `parse` calls `parser.advance()` itself (the block parser does not do this for you) and returns an `md.Element.empty('databaseEmbed')` carrying `title`/`view` as element attributes; returning `null` here still consumes the line since `advance()` already ran, so a syntax that decides mid-`parse` that a line isn't really an embed must not reach that state (the regex should already have decided).
- Register the syntax via `MarkdownBody(blockSyntaxes: [DatabaseEmbedSyntax()], ...)`. It runs alongside the default block syntaxes (paragraph, heading, etc.), tried in order per line; a whole line matching the pattern is claimed before the paragraph syntax gets a chance at it.
- Render the element with a `MarkdownElementBuilder` registered under the same tag: `MarkdownBody(builders: {databaseEmbedTag: DatabaseEmbedBuilder()})`. Override `isBlockElement() => true` (required — without it the builder is only consulted for inline spans and the block never reaches it) and `visitElementAfterWithContext(context, element, preferredStyle, parentStyle)` (the non-deprecated hook; `visitElementAfter` still exists but is deprecated) to return the custom widget, reading `title`/`view` back off `element.attributes`.
- **Gotcha confirmed by the spike:** inline `![[x]]` sitting inside a paragraph with other text (`See ![[Projects]] for details.`) and plain `[[x]]` wikilinks are untouched — the block syntax never sees them because the paragraph syntax claims that line first (the embed pattern doesn't match a line with leading/trailing text), so they fall through to ordinary text rendering exactly as today. No wikilink-specific handling was needed to achieve this; it's a consequence of the syntax being anchored and block-level only.
- The real `DatabaseEmbed(title, view)` (task 7.2) replaces the spike's placeholder `Text`-in-`Container` builder body with a widget that maps the title to an id through `DatabasesController`'s list, fetches the cached full definition for view names, and reuses the table/board widgets in read-only mode with `limit: 50`. The embed is given a bounded height with its own scroll inside the reading column's `SingleChildScrollView`, and tap handlers are wrapped so they work inside the surrounding `SelectionArea`.

**Schema editor is a full-screen form** driven by a local mutable copy of `DatabaseDefinition`; filters are edited with a small condition-list builder (property, op, value, and an and/or toggle at each nesting level, one level of nesting supported in the UI, deeper nesting displayed read-only as JSON). Save sends the whole `properties` and `views` sections, per the server's wholesale-replace semantics.

**Routing:** `GoRoute('/databases/:id')` inside the same `ShellRoute` as `/notes/:id`; the server's `static_web_middleware` dual-use path check gains `GET /databases/{id}` (not the bare list), with `Vary: Accept, Authorization`, tracked as a task here because it is client-serving behavior and as an `auth` spec delta.

**Sidebar:** `FolderTreeSidebar` gains a Databases section fed by a `DatabasesController` that fetches `GET /databases` and refreshes on any `changed` event with a 1 s debounce (cheap call, avoids tracking which notes are definitions).

## Risks / Trade-offs

- [Risk] flutter_markdown_plus custom block syntax API may differ across versions → Mitigation: confirmed working on `flutter_markdown_plus: ^1.0.12` / `markdown: ^7.3.1` by the task-1.1 spike; the segment pre-pass fallback was not needed. If a future version breaks the `BlockSyntax`/`MarkdownElementBuilder` contract, fall back to a line-splitting pre-pass that renders embeds as separate widgets between `MarkdownBody` segments.
- [Risk] Wildcard `changed` subscription on the database screen causes frequent re-queries in busy vaults → Mitigation: 1 s debounce and only re-query while the screen is mounted.
- [Risk] Client-side covering-database detection drifts from the server rule → Mitigation: both sides call the `coveringDatabases` helper in `shared` that `add-databases` introduces; the client treats it as best-effort for choosing editors and the server rejects anything invalid.
- [Risk] A 409 from `PUT /databases/{id}` has no `current` note in its body and the client's error mapper would surface it as a generic server error → Mitigation: extend the mapper so `version_conflict` without `current` becomes a `VersionConflictException` with a null `current`.
- [Trade-off] Board has no manual ordering → accepted; rows sort by the view's sort.
- [Trade-off] Filter editor supports one nesting level → accepted; deeper filters remain editable via MCP or by hand.
