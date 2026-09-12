## Why

Folders in the vault are purely a derived projection over notes' `path` field — `GET /notes/tree` only lists a folder once it directly contains at least one note (`notes-api`: "GET /notes/tree returns the folder hierarchy"). There is no way, via the REST API, the MCP tools, or the Flutter sidebar, to create a folder before putting a note in it. Anyone organizing their vault Obsidian-style expects to sketch out a folder structure first and fill it in later; today they must create a throwaway note just to make a folder appear.

## What Changes

- The server gains a way to persist an empty folder on disk: an empty directory alone is enough (the filesystem is already the canonical source of truth per `notes-storage`), but the metadata index needs a way to know about it. A small marker file (not a note — carries no `.md` extension, is excluded from every note listing/search/link/tag operation) is written into the folder to make its existence durable and rebuildable on restart, exactly like note files are today.
- New endpoint: `POST /notes/tree` accepts `{ "path": "<folder>" }`, creates the directory (and the marker file) if it doesn't exist, and returns `{ path, note_count: 0 }`. Idempotent: creating a folder that already exists (with or without notes) returns 200 with its current `note_count` rather than an error. Path collisions with an existing _note_'s title are impossible by construction (notes always carry `.md`, folders never do — an existing invariant), so the only conflict case is a case/NFC-only collision with another folder, which resolves to the same folder rather than erroring.
- New MCP tool `create_folder` mirroring the endpoint.
- Flutter: a "New folder" action in the sidebar (folder icon in the sidebar header) opens a text prompt for the folder path and calls the new endpoint, then refreshes the tree.
- `GET /notes/tree` now also lists folders that have zero notes but do have a marker file, so a freshly created empty folder appears immediately.

## Capabilities

### New Capabilities

(none — this extends existing capabilities rather than introducing a new one)

### Modified Capabilities

- `notes-storage`: adds the empty-folder marker file as a second kind of on-disk artifact alongside note files, and defines how the startup scan and folder-derivation logic account for it.
- `notes-api`: adds `POST /notes/tree` and updates the `GET /notes/tree` requirement so a marker-only folder is included.
- `mcp-server`: adds the `create_folder` tool to the catalog.
- `flutter-client`: adds a "New folder" sidebar action.

## Impact

Server: `storage.dart` (marker file read/write, startup scan), `meta_index.dart` (track marker-only folders), `routes/notes/tree.dart` (new `POST` handler), `mcp/tools.dart` (new tool). Flutter: `folder_tree_sidebar.dart` (new action + dialog), `api_client.dart` (new `createFolder` method). No changes to auth, locking, or realtime beyond an optional `changed`-style folder-tree refresh signal already covered by existing `moved`/`created`/`deleted` triggers (a folder create doesn't need a new broadcast action — the client can just re-fetch the tree after its own successful create).

## Non-goals

- No folder deletion (empty or otherwise) — matches the existing non-goal from `add-vault-structure` ("no automatic empty-folder pruning"); this proposal only adds creation.
- No folder rename as a distinct operation — a folder's effective name already changes when every note under it is moved (existing behavior); renaming an _empty_ folder is out of scope here and would need its own proposal if wanted.
- No nested "create parent folders automatically beyond what's implied by the path" ambiguity to resolve — creating `A/B/C` creates the full chain, mirroring how a note's `path` already implies intermediate directories today.
