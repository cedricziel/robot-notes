## Why

The client grew its layouts one screen at a time: the notes list goes wide at 700px, the editor splits at 600px, and every screen paints its own banners. A UX review of the whole app found the seams: a wide desktop window still pushes a note over the list like a phone, "Account" immediately asks to disconnect, backlinks are pinned under the note instead of reading with it, and "Reconnecting…" looks different on each screen. This change gives the app one layout vocabulary and one shell.

## What Changes

- Shared Material 3 window size classes (compact <600, medium ≥600, expanded ≥840, large ≥1200) replace the ad-hoc 700/600 breakpoints. At large the app renders a three-pane shell (resizable folder sidebar | notes list | note); below large, notes push as full-screen pages.
- Notes list: "Upload file" in the wide toolbar (was FAB-only); empty states for no notes / empty folder / empty tag; folder scope in the title and as a clearable chip beside the tag chip; tags as plain text labels; path in the metadata line, hidden when scoped to that folder; resizable sidebar; selected-row highlight in the shell.
- Account: the bottom-nav "Account" destination and the wide toolbar's account button open an account sheet/dialog (server URL, display name, connection state, Disconnect). **BREAKING** for tests: the logout icon (`shell.reset`) leaves the toolbar.
- Note view: one scrolling reading column with metadata, body, tags, and backlinks aligned; back arrow when pushed, close when shown as a pane; presence as stacked avatars with a tooltip; double-tap or Cmd/Ctrl+E enters edit mode; borderless, width-capped editor with a preview toggle (on at medium+, off on compact); one Markdown stylesheet for view and preview.
- Search: header row instead of an AppBar; centered palette (max 640 wide) on medium+, top sheet on compact; Cmd/Ctrl+K or Cmd/Ctrl+Shift+F opens it; Cmd/Ctrl+N creates a note.
- Consistency: one `StatusStrip` for every banner; the connection banner insets under the status bar once; setup's reachability icon uses the colour scheme; one relative-time module; one `AppTheme` builder.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: adds requirements for window-size-class layout, the account surface, keyboard shortcuts, notes-list empty states, and consistent status strips; modifies the notes list, note view, search view, routing, sidebar, realtime banner, and first-run requirements to match.

## Impact

- `app/lib/src/layout/`, `theme/`, `widgets/`, `format/`: shared foundations; `app/lib/src/notes/`, `search/`, `setup/`: screen adoption; `app/lib/src/app_router.dart`, `app/lib/main.dart`: shell route, account surface, shortcuts, overlay presentation; `app/README.md`: replaces the Flutter template boilerplate.
- Builds on the unarchived `redesign-search-as-overlay` and `redesign-login-reachability-and-layout` changes; the spec delta targets `flutter-client` as it stands once those are archived.

## Non-goals

- An always-editable note (no explicit edit mode). Rejected: entering edit mode acquires the server-side editor lock, and holding a lock for every open note would block other humans and agents from writing. Double-tap / Cmd+E is the compromise.
- No server or API changes; no change to setup's two steps, OIDC sign-in, the conflict view, autosave, or lock heartbeats.
