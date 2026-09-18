## Why

The `add-databases` change gives the server typed properties, database definitions, views, and query endpoints, but nothing in the Flutter app can show or edit them. Without a client, only agents benefit. This change makes databases usable by people: browse a database as a table, list, or board, edit properties without touching raw YAML, and see a database view embedded inside a note.

## What Changes

- A **database screen** at `/databases/{id}` renders a saved view as a table, list, or board, with a view switcher, and the view's filter, sort, and grouping applied by the server. Table cells and list rows open the row note; table cells are editable inline; board cards drag between columns to change the grouped property.
- A **property panel** at the top of the note view shows the note's properties with type-aware editors (text, number, checkbox, date picker, select, multi-select chips, relation picker with the existing link autocomplete, url). Edits go through `PATCH /notes/{id}/properties` and never touch the body buffer. Live `changed` events refresh the panel even while the body is being edited.
- The **sidebar** gains a Databases section listing every database from `GET /databases`; selecting one opens the database screen. A "New database" action opens a form for title, folder or tag source, properties, and a first view, submitted to `POST /databases`. A "New row" action on the database screen posts to `POST /databases/{id}/rows` and opens the new note in edit mode.
- The **schema editor** on the database screen lets the user add, rename the label of, retype, and remove properties, edit select options, and add, edit, reorder, and delete views, submitted via `PUT /databases/{id}` with the current version.
- **Embeds**: `![[Database Title]]` and `![[Database Title#View]]` in a note body render, in view mode, as a read-only inline rendering of that view (table for table and list views, columns for board), with a header linking to the database screen and rows linking to their notes. Unresolvable embeds render as the literal text.
- API client and shared DTOs from `add-databases` are reused; the client gains typed methods for every new endpoint.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: new requirements for the database screen and its three view types, the property panel, the sidebar databases section and creation flow, the schema editor, embed rendering, and routing for `/databases/{id}`.
- `auth`: `GET /databases/{id}` joins the dual-use paths that serve the web app to a browser navigation.

## Impact

- `app/lib/src/databases/` (new): controllers, screen, table, list, board, cell editors, schema editor, embed widget.
- `app/lib/src/notes/note_screen.dart`, `note_controller.dart`: property panel, embed rendering in markdown, changed-event refresh of properties.
- `app/lib/src/notes/folder_tree_sidebar.dart`: databases section.
- `app/lib/src/api/api_client.dart`: database methods, properties on `Note`.
- `app/lib/src/app_router.dart`: new route; server static-web fallback list.
- Depends on the `add-databases` server change being merged and released.

## Non-goals

- Gallery and calendar views.
- Formula, rollup, person, or attachment properties.
- Ad hoc filter or sort editing inside an embed; embeds always show a saved view.
- Column resizing, column reordering persistence, or per-user view state on the server.
- Offline editing of properties.
- A block editor; embeds are text in the markdown source, exactly like wikilinks today.
