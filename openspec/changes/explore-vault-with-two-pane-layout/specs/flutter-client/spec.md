## MODIFIED Requirements

### Requirement: Sidebar presents the vault as a folder tree

The app SHALL provide a vault tree backed by `GET /notes/tree`, exact-folder note metadata, and direct file metadata. The tree SHALL show expandable folders, their direct note counts, notes by title, non-note files by filename, and an All notes entry. It SHALL include root-level items, explicitly created empty folders, and folders containing only files. Folders SHALL precede document entries. Within each group, entries SHALL sort case-insensitively by display name, with a stable identity as the tie-breaker. Notes SHALL use note identity and SHALL NOT also appear as non-note files.

Selecting a folder name SHALL open its direct contents overview. Its separate chevron SHALL expand or collapse children without changing the main destination. The tree SHALL load document metadata on expansion, without fetching note bodies or file bytes, and SHALL expose further note pages through a Load more action. Loaded pages SHALL sort together. Collapsing and reopening a loaded folder SHALL preserve its contents and expansion state for the current vault session.

The tree SHALL refresh hierarchy and invalidate affected loaded contents on note creation, move, deletion, and title updates. A successful local upload or folder creation, and an explicit refresh, SHALL refresh affected contents. A folder SHALL remain visible when it still contains files, descendants, or an explicit empty-folder marker. Loading and failure SHALL be visible per folder, with a retry action that preserves other loaded folders.

#### Scenario: Tree renders folders from the server

- **WHEN** the server reports `Projects/Alpha` and `Projects/Beta`
- **THEN** the tree SHALL render an expandable Projects node containing Alpha and Beta

#### Scenario: Selecting a folder scopes the list

- **WHEN** the user selects the Projects name
- **THEN** the main area SHALL show its direct contents overview
- **WHEN** the user activates its chevron
- **THEN** its children SHALL expand without changing the main destination

#### Scenario: Documents appear under their immediate folder

- **GIVEN** Projects contains a note Plan, a file diagram.png, and a child folder Alpha containing another note
- **WHEN** Projects expands
- **THEN** Alpha SHALL precede Plan and diagram.png
- **AND** the note inside Alpha SHALL appear only when Alpha expands

#### Scenario: Root, empty, and file-only folders are discoverable

- **WHEN** the vault has root-level documents, an explicit empty folder, and a folder containing only files
- **THEN** each SHALL be reachable through the tree

#### Scenario: Expansion loads metadata progressively

- **WHEN** the user expands a folder with more notes than one page
- **THEN** the tree SHALL show the first metadata page and a Load more action
- **AND** unopened sibling folders SHALL NOT load their documents
- **AND** no document content SHALL be fetched until a document opens

#### Scenario: Failed expansion can be retried

- **WHEN** a folder metadata request fails
- **THEN** that folder SHALL show an error and retry action while other loaded folders remain usable

#### Scenario: Tree updates after a live move

- **WHEN** a note moves between two loaded folders
- **THEN** the tree SHALL refresh the hierarchy and both folders' contents without duplicating the note

#### Scenario: Tree updates after a live delete empties a folder

- **WHEN** the last note in a folder is deleted
- **THEN** the tree SHALL remove that note and remove the folder only if no files, descendants, or explicit marker remain

#### Scenario: Titles and local uploads refresh the tree

- **WHEN** a note title changes or a local file upload succeeds
- **THEN** the affected loaded folder SHALL show the updated title or new file

#### Scenario: Creating a new folder from the sidebar

- **WHEN** the user selects New folder, enters Ideas, and confirms
- **THEN** the app SHALL call `POST /notes/tree` with the selected path and refresh the tree on success

#### Scenario: Folder creation failure shows a real error

- **WHEN** folder creation fails
- **THEN** the app SHALL keep the prompt open and show the server message or a useful fallback

## ADDED Requirements

### Requirement: Desktop workspace uses two panes

At window widths of at least 840 logical pixels, the workspace SHALL show a resizable vault tree and one main area. It SHALL NOT retain a permanent middle list pane beside an open document. The main area SHALL show one destination at a time: a folder overview, All notes, a note, a file, or a database. Sidebar width preferences and accessible resize controls SHALL remain available. Below 840 logical pixels, navigation SHALL use the existing compact or stacked presentation with the same tree contents.

Folder overviews SHALL show direct child folders, notes, files, breadcrumbs to ancestors and vault root, and the applicable creation and upload actions. All notes SHALL retain the existing note list's filtering, sorting, pagination, and note actions in the main area. Search SHALL remain an overlay with its existing keyboard behavior.

#### Scenario: Open a note on desktop

- **WHEN** a user opens a tree note at a width of 1000 logical pixels
- **THEN** the tree and editor SHALL be visible with no permanent list between them

#### Scenario: Browse a folder

- **WHEN** the user selects a folder
- **THEN** its overview SHALL replace the document in the main area and show direct contents and ancestor breadcrumbs

#### Scenario: All notes and search remain available

- **WHEN** the user selects All notes and then opens search
- **THEN** the note list SHALL occupy the main area and search SHALL appear as an overlay

#### Scenario: Resize across the desktop boundary

- **WHEN** the width changes between 839 and 840 logical pixels while a note is open
- **THEN** the presentation SHALL change without losing the active note or its draft

### Requirement: Vault document navigation preserves context and edits

Selecting a tree note SHALL open its existing note URL and editor. Selecting a file SHALL open a file destination in the main area using authenticated access. Images within the client preview size limit SHALL have an inline preview. Oversized images and other file types SHALL have a file details view with filename, type, size, and an explicit download action. Failed or unavailable files SHALL show an error and retry or return action.

The active document SHALL be highlighted in the tree, with ancestors expanded and its row revealed, including notes opened from search or a deep link. Revealing an item beyond the first note page SHALL load the required metadata pages. Closing a document opened from an overview or All notes SHALL restore that view's filters and scroll position. A directly opened note with no browse history SHALL return to All notes. Folder breadcrumbs SHALL navigate to the selected ancestor overview.

Every action that leaves an edited note, including switching vaults, SHALL use the existing pending-edit guard before changing configuration or disposing the session. If saving fails or navigation is cancelled, the current note, draft, selection, and browse state SHALL remain intact. Switching vaults SHALL clear tree caches and browse state before loading the new vault.

#### Scenario: Open a file

- **WHEN** the user selects an image file in the tree
- **THEN** the main area SHALL show its authenticated preview
- **WHEN** the user selects another file type
- **THEN** the main area SHALL show file details and a download action

#### Scenario: Reveal a deep-linked note

- **WHEN** a user opens an existing note URL for a note inside collapsed folders or on a later metadata page
- **THEN** the app SHALL expand its ancestors, reveal its row, and highlight it

#### Scenario: Return to browse context

- **GIVEN** a user opens a note from a filtered and scrolled All notes view
- **WHEN** the note closes
- **THEN** the app SHALL restore the previous filters and scroll position

#### Scenario: Failed save blocks folder navigation

- **GIVEN** the current note has pending edits
- **WHEN** the user selects a folder and saving fails
- **THEN** the note and draft SHALL remain visible and the selected tree item SHALL remain unchanged

#### Scenario: Failed save blocks vault switching

- **GIVEN** the current note has pending edits
- **WHEN** the user switches vaults and saving fails or departure is cancelled
- **THEN** the previous vault configuration, draft, tree selection, and browse cache SHALL remain intact

#### Scenario: Vault switch discards previous tree metadata

- **WHEN** the user successfully switches vaults
- **THEN** the tree SHALL show only the new vault's items without reusing previous cached contents
