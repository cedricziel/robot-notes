## MODIFIED Requirements

### Requirement: Note view supports edit, lock, and concurrency UX

When the user opens a note, the app SHALL `GET /notes/{id}`, subscribe to its WS events, and acquire the editor lock before allowing edits. While editing, the app SHALL heartbeat the lock periodically. The app SHALL automatically save edits approximately 2 seconds after the user stops changing the title or content, using the same save path as an explicit save; this automatic save SHALL NOT run while the conflict view is shown, and SHALL resume once a conflict is resolved and editing continues. On save (automatic or explicit) the app SHALL `PUT /notes/{id}` with the version it last loaded. The app SHALL handle 409 by presenting a conflict view with the server's title and content beside the user's own, editable, title and content; the view SHALL mark the title when the two differ and SHALL mark the content lines each side has that the other does not. The user SHALL be able to take the server's version, or edit their own version in place and save it against the server's current version. The app SHALL handle 423 by switching to read-only mode and surfacing the lock holder.

#### Scenario: Edit acquires the lock

- **WHEN** the user enters edit mode on a note
- **THEN** the app SHALL `POST /notes/{id}/lock` and proceed only on 200

#### Scenario: Entering edit mode uses the note as it exists after the lock is acquired

- **GIVEN** the note was loaded at version 1 and another actor has since updated it to version 2
- **WHEN** the user enters edit mode and the lock is acquired
- **THEN** the app SHALL `GET /notes/{id}` again and seed the edit buffers and `If-Match` baseline from version 2

#### Scenario: Failed re-fetch after acquiring the lock releases it

- **GIVEN** the lock was acquired
- **WHEN** the follow-up `GET /notes/{id}` fails
- **THEN** the app SHALL `DELETE /notes/{id}/lock`, stay in read-only mode, and surface the error

#### Scenario: Heartbeat extends the lock during editing

- **GIVEN** the user is in edit mode
- **WHEN** roughly half the TTL elapses between keystrokes
- **THEN** the app SHALL `PUT /notes/{id}/lock` to extend it

#### Scenario: Typing mid-text keeps the caret in place

- **GIVEN** the user is in edit mode with the caret placed inside the title or content
- **WHEN** the user types
- **THEN** the characters SHALL be inserted at the caret and the caret SHALL stay right after them; syncing the edit buffers back into the fields SHALL NOT move it

#### Scenario: Save uses If-Match

- **GIVEN** a note loaded at version 5
- **WHEN** the user saves
- **THEN** the app SHALL send `PUT /notes/{id}` with header `If-Match: 5`

#### Scenario: Edits are saved automatically after a pause in typing

- **GIVEN** the user is in edit mode
- **WHEN** approximately 2 seconds pass with no further change to the title or content
- **THEN** the app SHALL `PUT /notes/{id}` with the current edit buffers and `If-Match` from the last-loaded version, without any user action

#### Scenario: A new edit within the debounce window postpones the automatic save

- **GIVEN** the user is in edit mode and stopped typing less than 2 seconds ago
- **WHEN** the user types again before the automatic save fires
- **THEN** the pending automatic save SHALL be postponed to run 2 seconds after this latest change instead

#### Scenario: Automatic save does not run while the conflict view is shown

- **GIVEN** a save returned 409 and the conflict view is showing
- **WHEN** approximately 2 seconds pass
- **THEN** the app SHALL NOT `PUT /notes/{id}` automatically; saving only happens when the user chooses "Use server version" or "Save mine"

#### Scenario: 409 prompts the user to reconcile

- **GIVEN** the local copy is at version 5 but the server is at version 7
- **WHEN** the save returns 409
- **THEN** the app SHALL present the server's current title and content, the user's local edits, and a clear path to retry the save against the new version

#### Scenario: Conflict view shows both titles

- **GIVEN** the save returned 409 and the server's title differs from the user's
- **WHEN** the conflict view is shown
- **THEN** the server pane SHALL show the server's title, the user's pane SHALL show the user's title, and both SHALL be marked as differing

#### Scenario: Conflict view marks the lines the versions do not share

- **GIVEN** the server's content is `a`, `b`, `c` and the user's is `a`, `b`, `d`
- **WHEN** the conflict view is shown
- **THEN** the server pane SHALL mark `c`, the user's pane SHALL mark `d`, and neither SHALL mark `a` or `b`

#### Scenario: Editing yours in the conflict view and saving mine sends the edited text

- **GIVEN** the conflict view is shown with the server at version 7
- **WHEN** the user edits the content in the "Yours" pane and taps "Save mine"
- **THEN** the app SHALL send `PUT /notes/{id}` with the edited title and content and `If-Match: 7`

#### Scenario: Conflict panes stack on narrow screens

- **WHEN** the conflict view is narrower than 600 logical pixels
- **THEN** the server pane SHALL be shown above the user's pane instead of beside it

#### Scenario: 423 switches to read-only

- **GIVEN** another actor holds the lock
- **WHEN** the user opens the note
- **THEN** the app SHALL display a banner naming the lock holder and SHALL disable editing controls

#### Scenario: Closing the editor releases the lock

- **WHEN** the user navigates away from a note they had locked
- **THEN** the app SHALL `DELETE /notes/{id}/lock`

#### Scenario: Keyboard shortcuts save and close

- **GIVEN** the user is editing a note, including while a text field has focus
- **WHEN** they press Cmd+S (macOS) or Ctrl+S (other platforms)
- **THEN** the app SHALL save the note the same way as tapping "Save"
- **WHEN** they press Escape
- **THEN** the app SHALL trigger the same close flow as tapping the close button

### Requirement: Save and lock outcomes are surfaced in the note view

The note view SHALL confirm a completed explicit save and SHALL show the server's message when an explicit save or lock acquisition fails, so the user is never left silently in the editor after taking an explicit action. Outcomes the view already renders — 409 (conflict view) and 423 (lock banner) — SHALL NOT additionally produce a message. An automatic (debounced) save SHALL NOT produce a "Saved" confirmation message; its outcome is reflected only by the editing-status indicator, so it never interrupts typing. An automatic save that fails with neither 409 nor 423 SHALL also produce no message — the editing-status indicator showing "Unsaved changes" is sufficient, and the failure SHALL NOT block further typing.

#### Scenario: Successful save is confirmed

- **GIVEN** the user is editing a note
- **WHEN** the user taps "Save" (or the keyboard shortcut) and it returns 200 with version 7
- **THEN** the app SHALL show a brief "Saved (v7)" confirmation and stay in edit mode

#### Scenario: Failed save shows the server message

- **GIVEN** the user is editing a note
- **WHEN** the user taps "Save" and it fails with a status other than 409 or 423 (for example 400 for an empty title)
- **THEN** the app SHALL show a message containing the server's `message` and SHALL stay in edit mode with the edits intact

#### Scenario: Failed lock acquisition shows the server message

- **WHEN** `POST /notes/{id}/lock` fails with a status other than 423
- **THEN** the app SHALL show a message containing the server's `message` and remain read-only

#### Scenario: A successful automatic save shows no confirmation message

- **GIVEN** the user is editing a note
- **WHEN** the debounced automatic save returns 200
- **THEN** the app SHALL NOT show a "Saved" confirmation message; the editing-status indicator SHALL update instead

#### Scenario: A failed automatic save shows no error message

- **GIVEN** the user is editing a note
- **WHEN** the debounced automatic save fails with a status other than 409 or 423
- **THEN** the app SHALL NOT show an error message; the editing-status indicator SHALL show "Unsaved changes" and the user MAY continue typing or save explicitly

## REMOVED Requirements

### Requirement: Unsaved edits are not discarded without confirmation

**Reason**: Automatic saving means edits are persisted within roughly 2 seconds of the last keystroke, so there is nothing meaningfully unsaved left to confirm discarding by the time the user leaves the note.

**Migration**: Leaving the note view now flushes any pending edit with an immediate save instead of prompting — see "Editor flushes pending edits when closing".

## ADDED Requirements

### Requirement: Editor flushes pending edits when closing

When the user leaves the note view — via the close button, the browser back button, or the OS back gesture — while the edit buffers differ from the loaded note, the app SHALL attempt an immediate save before leaving, instead of asking for confirmation. Leaving with unchanged buffers SHALL NOT trigger a save. The outcome of that flush determines whether the note view actually closes.

#### Scenario: Leaving with a pending edit saves it and closes

- **GIVEN** the user is editing a note and has changed the title or content
- **WHEN** they tap close or trigger back navigation
- **THEN** the app SHALL `PUT /notes/{id}` immediately, and on success SHALL release the lock and leave the note view

#### Scenario: Leaving without edits does not trigger a save

- **GIVEN** the user is editing but the buffers match the loaded note
- **WHEN** they tap close or trigger back navigation
- **THEN** the app SHALL NOT `PUT /notes/{id}`, and SHALL release the lock and leave immediately

#### Scenario: A flush that hits a conflict keeps the note open

- **GIVEN** the user is editing a note with a pending edit
- **WHEN** they tap close and the flush save returns 409
- **THEN** the app SHALL present the conflict view and SHALL NOT leave the note view

#### Scenario: A flush that hits a transient error keeps the note open

- **GIVEN** the user is editing a note with a pending edit
- **WHEN** they tap close and the flush save fails with a status other than 409 or 423
- **THEN** the app SHALL show a message containing the server's `message`, SHALL keep the edits intact, and SHALL NOT leave the note view

#### Scenario: A flush that loses the lock still closes

- **GIVEN** the user is editing a note with a pending edit
- **WHEN** they tap close and the flush save fails with 423 because another actor took the lock
- **THEN** the app SHALL switch to read-only mode, drop the local edits, and leave the note view, consistent with losing the lock during any other save

### Requirement: Editing status indicator shows save state at a glance

While editing, the note view SHALL show who is editing and whether their most recent change has been saved, without requiring the user to open a menu.

#### Scenario: A save in flight shows "Saving…"

- **GIVEN** the user is editing a note
- **WHEN** a save (automatic or explicit) is in flight
- **THEN** the editing status SHALL read "Saving…"

#### Scenario: A pending, not-yet-saved edit shows "Unsaved changes"

- **GIVEN** the user is editing a note
- **WHEN** the edit buffers differ from the last-saved note and no save is currently in flight
- **THEN** the editing status SHALL read "Unsaved changes"

#### Scenario: A saved note shows when it was last saved

- **GIVEN** the user is editing a note
- **WHEN** the edit buffers match the last-saved note
- **THEN** the editing status SHALL read "Autosaved" followed by the last-saved time
