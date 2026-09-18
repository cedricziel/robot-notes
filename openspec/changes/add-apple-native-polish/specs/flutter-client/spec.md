## ADDED Requirements

### Requirement: Chrome adapts to Apple platforms

On iOS and macOS the client SHALL follow the platform's own conventions for the controls it renders, while keeping one widget tree: no ink ripples; Cupertino alert dialogs (with Cupertino dialog actions and a Cupertino text field where a dialog collects input) for delete, move, new-folder, and disconnect confirmations; platform spinners; a chevron as the back glyph and horizontal dots as the "more" glyph; centered app-bar titles on iOS; and `Menlo` for code in notes. On iOS only, the note view's "more" button SHALL open an action sheet with a Cancel button and a destructive Delete; macOS SHALL keep a popup menu. Every such decision SHALL key off the theme's platform so tests can pin it. Android, Windows, Linux, and Web SHALL keep Material chrome.

#### Scenario: Delete confirmation is a Cupertino dialog on iOS

- **GIVEN** the app runs with an iOS theme
- **WHEN** the user asks to delete a note from the list or the note view
- **THEN** the confirmation SHALL be a Cupertino alert whose "Delete" action is marked destructive, and confirming SHALL send `DELETE /notes/{id}` exactly as the Material dialog does

#### Scenario: Note actions are an action sheet on iOS and a menu on macOS

- **GIVEN** a note is open in read-only view
- **WHEN** the user taps the "more" button on iOS
- **THEN** an action sheet SHALL offer "Move to folder…", a destructive "Delete note", and "Cancel", and choosing an action SHALL run it only after the sheet has been dismissed
- **WHEN** the user taps the "more" button on macOS
- **THEN** a popup menu SHALL offer the same actions and no action sheet SHALL appear

#### Scenario: Material chrome elsewhere

- **GIVEN** the app runs with an Android, Windows, or Linux theme
- **WHEN** any of the dialogs above is shown
- **THEN** it SHALL be a Material alert with Material buttons, and the back and "more" glyphs SHALL be the Material arrow and vertical dots

### Requirement: Pull-to-refresh follows the platform

On iOS and macOS the notes list SHALL use the iOS overscroll pull-to-refresh control and the note view's pull-to-refresh SHALL use the platform spinner; elsewhere both SHALL keep the Material refresh indicator. Either SHALL perform the same re-fetch. The swipe-to-delete on list rows (see the `add-touch-gestures` change) SHALL additionally give haptic feedback. The list SHALL be the screen's primary scrollable so a tap on the iOS status bar scrolls it to the top.

#### Scenario: Pull-to-refresh control follows the platform

- **GIVEN** the list is on screen
- **WHEN** the app runs with an iOS or macOS theme
- **THEN** pulling past the top SHALL show the Cupertino refresh control and re-fetch the first page
- **WHEN** the app runs with an Android theme
- **THEN** the Material refresh indicator SHALL be shown instead

#### Scenario: Swipe-to-delete under an Apple theme

- **GIVEN** the list renders under an iOS theme with a note "A"
- **WHEN** the user swipes "A" from its trailing edge
- **THEN** the confirmation SHALL be a Cupertino alert, confirming SHALL `DELETE /notes/{id}` and drop the row, and cancelling SHALL spring the row back with no request

### Requirement: macOS has a native menu bar

On the macOS desktop build the app SHALL install its own menu bar with the app menu (About, Account… ⌘,, Services, Hide, Hide Others, Show All, Quit), File (New Note ⌘N, New Folder… ⇧⌘N, Upload File…, Save ⌘S), Edit (Undo, Redo, Cut, Copy, Paste, Select All), View (Search ⌘K, Refresh ⌘R, Enter Full Screen), Note (Edit Note ⌘E, Close Note, Move to Folder…, Delete Note), and Window (Minimize, Zoom, Close Window ⌘W). An item SHALL be enabled only while its command applies: File/View items while the notes shell is on screen, Save while editing, Edit Note/Move/Delete while viewing, Close Note while a note is loaded. On macOS the menu bar SHALL own the ⌘ chords shown on its items, so a press invokes exactly one handler; Ctrl chords, Escape, and ⇧⌘F SHALL stay in-app. Edit-menu items SHALL forward the corresponding text-editing intent to whatever has keyboard focus. Close Window SHALL hide the window to the menu-bar tray (the same as the red close button). No menu bar SHALL be installed on any other platform, including a Mac browser.

#### Scenario: Items reflect the front screen

- **GIVEN** the app is on the setup screen
- **THEN** File › New Note and View › Refresh SHALL be disabled
- **WHEN** the user reaches the notes shell
- **THEN** they SHALL be enabled, and choosing File › New Note SHALL create a note in the selected folder and open it

#### Scenario: Note items follow the note's mode

- **GIVEN** a note is open read-only
- **THEN** Note › Edit Note SHALL be enabled and File › Save disabled
- **WHEN** the user chooses Edit Note
- **THEN** the editor SHALL open (acquiring the lock), Edit Note SHALL disable and Save SHALL enable
- **WHEN** the user chooses Save
- **THEN** the note SHALL be saved exactly as tapping "Save" does

#### Scenario: A note pushed over another takes the Note menu with it

- **GIVEN** note A is open and note B is pushed on top of it
- **THEN** the Note menu SHALL act on B
- **WHEN** B is closed
- **THEN** the Note menu SHALL act on A again

#### Scenario: One handler per chord

- **GIVEN** the macOS desktop build
- **WHEN** the user presses ⌘N
- **THEN** exactly one note SHALL be created, because the in-app shortcut map SHALL NOT bind ⌘N there while the menu bar does

#### Scenario: Other platforms

- **GIVEN** the app runs on iOS, Android, Windows, Linux, or Web
- **THEN** no platform menu SHALL be installed and the in-app shortcut maps SHALL be unchanged

### Requirement: Refresh and account shortcuts

Cmd+R (macOS) and F5 SHALL re-fetch the notes list; Cmd+, (macOS) and Ctrl+, (elsewhere) SHALL open the account surface. Both SHALL be active anywhere in the notes shell.

#### Scenario: Refresh from the keyboard

- **GIVEN** the notes shell is on screen
- **WHEN** the user presses Cmd+R or F5
- **THEN** the app SHALL re-issue `GET /notes` for the first page

#### Scenario: Account from the keyboard

- **GIVEN** the notes shell is on screen
- **WHEN** the user presses Cmd+, or Ctrl+,
- **THEN** the account surface SHALL open
