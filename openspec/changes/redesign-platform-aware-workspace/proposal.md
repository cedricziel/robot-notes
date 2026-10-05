## Why

Robot Notes already adapts individual dialogs and gestures to Apple platforms,
but its Material-shaped controls and action-only phone footer obscure the
workspace hierarchy. The approved concept uses quiet content surfaces,
rectangular controls, inset selections, a readable document header, and actual
phone destinations.

## What Changes

- Shared light/dark neutral palettes, indigo selection, system typography,
  8px controls and 12px panels.
- Inset folder and note selections, refined metadata, and Apple outline icons.
- Compact Notes / Databases / Search / Settings destinations. Visited
  destinations retain their state; compose and folder/upload actions remain
  available from the notes toolbar.
- Device-local System / Light / Dark appearance preference and persisted
  wide-workspace sidebar width. Settings retains connection, account, app-lock,
  and disconnect controls, and is reachable from the wide sidebar.
- A document title and metadata above the reading content; grouped properties
  scroll with the document and retain field state when entering edit mode.
- Keyboard-selectable search results; iOS shortcut search uses a bottom sheet.
- Keyboard and semantic actions for resizing the sidebar, with reduced-motion
  handling for the resize indicator and compact search entrance.

## Capabilities

### Modified Capabilities

- `flutter-client`: presentation, compact destinations, local preferences,
  reading properties, and keyboard interaction.

## Impact

Flutter client only. Existing APIs, server-side locks, autosave, conflicts,
menus, deep links, file uploads, and biometric authentication remain in use.
Adds the Cupertino icon font; no design-library import migration.

## Non-goals

Native Share extensions, system share/export integration, new document windows,
native Settings windows, Liquid Glass platform views, favorites/recent sidebar
features, and offline draft storage. These were broader research ideas; this
change implements the approved visual direction and working navigation without
adding simulated functionality.
