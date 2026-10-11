## Why

Editing a note currently requires entering a separate Markdown source editor. A directly editable block document lets people write and organize notes in place while preserving portable Markdown files and agent access.

## What Changes

- Open notes in the block editor automatically, subject to the existing exclusive note lock.
- Support paragraphs, headings, bulleted and numbered lists, checkboxes, quotes, fenced code, and dividers.
- Add slash insertion, block conversion, drag reordering, accessible move actions, deletion, inline formatting, and links.
- Keep a Markdown source option over the same draft and preserve content outside the supported block set.
- Retain autosave, explicit save, version checks, conflict recovery, and lock lifecycle behavior.
- Require compatibility with the app's adaptive widgets, platform conventions, theme, and accessibility settings. Reuse shared controls and assess reusable improvements for contribution to the adaptive layer.

## Capabilities

### New Capabilities

- `block-note-editor`: Block interactions, Markdown round trips, source switching, and accessible editing.

### Modified Capabilities

- `flutter-client`: Automatic editor entry and block editing as the default presentation, with source editing available explicitly.

## Impact

The Flutter note screen, editor widgets, document conversion, and editor tests change. `NoteController` remains responsible for locking and persistence. Server endpoints, shared note contracts, Markdown files, and frontmatter remain compatible. No storage migration is required. Editor dependency selection must pass a focused compatibility check before adoption.

## Non-goals

Image insertion, table authoring, nested block authoring, columns, new database features, simultaneous collaborative editing, per-block server identities, and a new storage format are outside v1. Existing unsupported Markdown remains accessible through source editing.
