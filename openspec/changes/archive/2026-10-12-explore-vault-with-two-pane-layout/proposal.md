## Why

The folder-only tree makes users switch to a separate list to discover notes and files. Once the tree can open those items directly, the permanent desktop middle pane duplicates navigation and reduces document space.

## What Changes

- Show folders, notes, and non-note files in one vault tree, including root-level items and empty folders.
- Separate folder selection from expansion: the name opens an overview, while the chevron expands children.
- Load note and file metadata when a folder expands, with pagination, loading, error, and retry states.
- Open notes in the editor and files in a preview or a file details view with an explicit download action.
- Use two desktop panes: a resizable vault tree and one main area for a folder overview, All notes, a note, a file, or a database.
- Preserve folder breadcrumbs, navigation return state, active-item highlighting, note deep links, and save-before-navigation behavior.
- Keep search as the existing overlay and retain compact navigation on narrow screens.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `flutter-client`: Extend the folder tree to notes and files, define two-pane desktop navigation, and preserve browse context and pending edits.
- `notes-api`: Add an exact-folder note filter for lazy tree contents without changing the existing recursive path filter.

## Impact

The change affects `app_router.dart`, the workspace layout, folder tree controller and sidebar, list and note navigation, and authenticated file access in the API client. The server note-list endpoint and its tests gain an additive filter. Existing folder and file endpoints remain the source of metadata and file bytes. No storage migration is required.

## Non-goals

This change does not add tabs, split editors, drag-and-drop moves, file editing, a new upload protocol, or a new search experience. It does not replace compact layouts with a desktop shell or add file-change broadcasting solely for this feature.
