## Purpose

Enable direct block editing of notes while preserving Markdown storage, source access, and existing save and concurrency guarantees.

## ADDED Requirements

### Requirement: Supported blocks form an editable document

The editor SHALL support paragraphs, headings at levels 1 through 6, flat bulleted and numbered lists, checkboxes, quotes, fenced code with optional language labels, and dividers. The title SHALL remain separately editable. Enter SHALL split a paragraph at the caret and continue a nonempty list item. Enter in an empty list item SHALL exit the list. Code blocks SHALL accept literal newlines. Backspace at the start of a paragraph SHALL merge it with a preceding paragraph. Deleting the final block SHALL leave an empty paragraph available for typing.

#### Scenario: Split and join paragraphs

- **WHEN** the user presses Enter inside a paragraph
- **THEN** the text after the caret SHALL move to a new paragraph with focus at its start
- **WHEN** the user presses Backspace at that start
- **THEN** the paragraphs SHALL merge with the caret at the join

#### Scenario: Continue and exit a list

- **WHEN** the user presses Enter at the end of a nonempty list item
- **THEN** a new item SHALL receive focus
- **WHEN** the user presses Enter in that empty item
- **THEN** it SHALL become a paragraph

#### Scenario: Toggle a checkbox

- **WHEN** the user changes a checkbox state
- **THEN** the draft SHALL reflect the checked or unchecked state and schedule autosave

### Requirement: Users can insert and organize blocks

The editor SHALL provide a slash menu in an empty paragraph and a labelled insert action for all supported block types. Users SHALL be able to convert text blocks without losing text, reorder blocks by drag handle or move actions, and delete blocks. Converting to a type unable to retain content SHALL require an explicit destructive action. Escape SHALL dismiss an open menu before invoking note close.

#### Scenario: Insert with a slash command

- **WHEN** the user types `/` in an empty paragraph and selects a heading
- **THEN** the paragraph SHALL become a heading, the command text SHALL disappear, and typing SHALL continue there

#### Scenario: Reorder without dragging

- **WHEN** the user activates Move up on a block that has a predecessor
- **THEN** the blocks SHALL exchange positions while retaining content and the moved block's focus

#### Scenario: Cancel a menu

- **WHEN** the user presses Escape while the slash menu is open
- **THEN** the menu SHALL close without navigating away or changing document content

### Requirement: Inline editing supports formatting and undo

Users SHALL be able to apply bold, italic, inline code, and links to selected text through labelled actions. Platform shortcuts SHALL support bold, italic, undo, and redo. Text edits and structural block actions SHALL be undoable and redoable. Selection across supported blocks SHALL support copying, replacement, and deletion. Paste SHALL accept plain text and Markdown without silently discarding unsupported content. Composition input SHALL remain intact during editing and autosave.

#### Scenario: Undo a structural edit

- **WHEN** the user deletes a block and invokes undo
- **THEN** its content and position SHALL be restored
- **WHEN** the user invokes redo
- **THEN** the deletion SHALL be reapplied

#### Scenario: Format a selection

- **WHEN** the user selects text and applies bold
- **THEN** the selected text SHALL appear bold and serialize as Markdown emphasis without changing adjacent text

#### Scenario: Compose text during saving

- **WHEN** the user enters text with an input method while a save completes
- **THEN** composition, selection, and newer unsaved text SHALL remain intact

### Requirement: Markdown and source switching preserve content

Markdown SHALL remain the persisted note body. Opening a note or switching presentations without editing SHALL preserve the body byte-for-byte and SHALL NOT trigger a save. Editing a supported block SHALL preserve untouched source spans, including unsupported syntax. Unsupported constructs such as tables, nested lists, images, and extensions SHALL remain opaque blocks with an action to edit their source. Both presentations SHALL share one draft and version baseline. Switching SHALL retain pending edits and SHALL NOT save or acquire another lock by itself. If conversion fails, the app SHALL keep the exact draft available in source mode and explain the failure.

#### Scenario: Preserve unsupported content

- **GIVEN** a note contains a paragraph and a Markdown table
- **WHEN** the user edits the paragraph and saves
- **THEN** the table's source SHALL remain byte-for-byte unchanged

#### Scenario: Switch with pending edits

- **WHEN** the user edits a heading and switches to source before autosave
- **THEN** source SHALL contain the edited heading
- **WHEN** the user edits that source and switches back
- **THEN** blocks SHALL reflect the same draft without losing unsupported content

#### Scenario: Open and leave without changes

- **WHEN** the user opens a note, switches presentations, and closes it without edits
- **THEN** the body and version SHALL remain unchanged

### Requirement: Block editing retains save and accessibility guarantees

Block edits SHALL use the existing autosave, explicit save, close flush, conflict resolution, and lock-loss behavior. Conflict reconciliation SHALL use Markdown source. Lock loss SHALL prevent further mutations without discarding unsaved draft content. Block actions SHALL be keyboard accessible, screen-reader labelled, and usable by touch without hover or drag. Source mode SHALL obey the same editing restrictions.

#### Scenario: Recover from a conflict

- **WHEN** saving block edits returns a version conflict
- **THEN** the existing reconciliation view SHALL expose the complete local Markdown draft and the server version, with automatic saves suspended

#### Scenario: Lose the lock

- **WHEN** a save returns a lock error
- **THEN** both presentations SHALL become read-only while retaining the unsaved draft for recovery

#### Scenario: Operate with touch or a screen reader

- **WHEN** the user focuses a block's actions
- **THEN** insertion, conversion, move, and deletion SHALL be available through labelled controls without requiring hover or dragging

### Requirement: Editing integrates with adaptive presentation

The editing experience SHALL follow the application's adaptive presentation conventions in both block and source modes. Editor controls and overlays SHALL respect the selected platform, application theme, text scaling, reduced-motion preferences, and keyboard or touch interaction. Equivalent editing actions SHALL remain available across supported platforms. A narrow desktop window SHALL retain desktop interaction conventions.

#### Scenario: Editor follows the selected platform

- **WHEN** the editor is presented with an Apple or Material platform theme
- **THEN** its menus, formatting controls, and dialogs SHALL follow the same platform conventions as the surrounding application
- **AND** the supported editing actions SHALL remain available

#### Scenario: Accessibility preferences apply to editor overlays

- **GIVEN** increased text scaling and reduced motion are enabled
- **WHEN** the user opens an insertion menu or link dialog
- **THEN** its controls SHALL remain readable and reachable without clipped actions
- **AND** its transitions SHALL respect the reduced-motion preference

#### Scenario: Resizing preserves platform behavior

- **WHEN** a desktop editor window is resized to a narrow width
- **THEN** its layout SHALL adapt to the available space while retaining desktop menu, focus, and keyboard conventions

#### Scenario: Blocks share the available content width

- **WHEN** paragraphs, headings, checkboxes, and opaque blocks appear in one document
- **THEN** their drag handles SHALL share a consistent gutter
- **AND** checkboxes SHALL align with the content edge
- **AND** the document SHALL use the available pane width with consistent inset spacing

#### Scenario: Tables retain natural sizing

- **WHEN** a note contains a table
- **THEN** a small table SHALL retain its natural width
- **AND** a table wider than the content area SHALL scroll horizontally without widening the document

#### Scenario: Source editing uses one pane

- **WHEN** the user selects Markdown source at desktop, mobile portrait, or mobile landscape width
- **THEN** the source editor SHALL use one editing pane without a simultaneous preview
- **AND** switching back to Blocks SHALL retain the draft and show its rendered presentation

#### Scenario: Source access stays secondary

- **WHEN** the user opens an editable note in Blocks
- **THEN** Markdown source SHALL be available through the note's More menu without a persistent presentation selector
- **WHEN** the user enters source mode
- **THEN** Back to Blocks SHALL be available in the editor
- **AND** Back to Blocks SHALL not appear in Blocks mode
- **AND** returning to Blocks SHALL retain the draft and editing history
