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

**Board drag uses Flutter's `LongPressDraggable`/`DragTarget`** with column-level targets. On drop the controller patches optimistically (moves the card in local state, sends `PATCH`, reverts on error). No reordering within a column (no server-side order property exists).

**Property panel lives in `NoteController`** as a separate `properties`/`coveringDefinitions` slice of `NoteState`. `patchProperty` calls the API and updates `note.version` and `properties` in state without touching `editTitle`/`editContent`. The `ChangedEvent` handler gains a branch: when editing, refetch only via `GET /notes/{id}` and copy `properties` and `version` into state, leaving buffers alone; when not editing, existing full refresh applies. Covering definitions are found client-side by matching the note's `path` and `tags` against `GET /databases` entries' `source`, so the panel knows which editors to show without a new server endpoint.

**Embeds are rendered by a custom `MarkdownBody` block syntax.** flutter_markdown_plus supports custom `BlockSyntax` + `MarkdownElementBuilder`; a syntax matches a whole line `^!\[\[(.+?)(#(.+?))?\]\]$` and emits an `embed` element rendered by `DatabaseEmbed(title, view)`, which resolves the title through a shared `DatabasesController` (the sidebar's list) and reuses the table/board widgets in read-only mode with `limit: 50`. Non-matching lines fall through to the normal inline `[[...]]` handling. Alternative: preprocess the markdown string. Rejected: loses source positions and breaks selection.

**Schema editor is a full-screen form** driven by a local mutable copy of `DatabaseDefinition`; filters are edited with a small condition-list builder (property, op, value, and an and/or toggle at each nesting level, one level of nesting supported in the UI, deeper nesting displayed read-only as JSON). Save sends the whole `properties` and `views` sections, per the server's wholesale-replace semantics.

**Routing:** `GoRoute('/databases/:id')` next to `/notes/:id`; the server's static-web fallback pattern list gains `/databases/*` so reloads work (small server change, tracked as a task here because it is client-serving behavior).

**Sidebar:** `FolderTreeSidebar` gains a Databases section fed by a `DatabasesController` that fetches `GET /databases` and refreshes on any `changed` event with a 1 s debounce (cheap call, avoids tracking which notes are definitions).

## Risks / Trade-offs

- [Risk] flutter_markdown_plus custom block syntax API may differ across versions → Mitigation: spike task first; fall back to a line-splitting pre-pass that renders embeds as separate widgets between `MarkdownBody` segments.
- [Risk] Wildcard `changed` subscription on the database screen causes frequent re-queries in busy vaults → Mitigation: 1 s debounce and only re-query while the screen is mounted.
- [Risk] Client-side covering-database detection drifts from the server rule → Mitigation: same rule (path prefix with subfolders flag, tag membership) implemented in `shared` so both sides use one function; add a shared test.
- [Trade-off] Board has no manual ordering → accepted; rows sort by the view's sort.
- [Trade-off] Filter editor supports one nesting level → accepted; deeper filters remain editable via MCP or by hand.
