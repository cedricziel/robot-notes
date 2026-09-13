## ADDED Requirements

### Requirement: macOS app stays running via a menu-bar tray icon

On macOS, the app SHALL register a menu-bar (status item) icon at startup. The icon SHALL provide a menu with two actions: "Show robot-notes" and "Quit". Closing the app's main window SHALL hide the window and keep the process running with the tray icon visible, rather than terminating the app. This behavior is macOS-only; Android, iOS, Windows, Linux, and Web are unaffected and keep their existing close/quit behavior.

#### Scenario: Closing the window keeps the app running

- **GIVEN** the app is running on macOS with its main window open
- **WHEN** the user closes the main window
- **THEN** the window SHALL hide, the process SHALL keep running, and the menu-bar icon SHALL remain visible

#### Scenario: Tray icon is present at launch

- **WHEN** the app launches on macOS
- **THEN** a menu-bar icon SHALL appear before or immediately after the main window is shown

#### Scenario: Other platforms are unaffected

- **GIVEN** the app is running on Android, iOS, Windows, Linux, or Web
- **WHEN** the user closes or backgrounds the app
- **THEN** the app SHALL behave exactly as it did before this change, with no tray icon and no hide-on-close behavior

### Requirement: Tray menu restores the single existing window

Selecting "Show robot-notes" from the tray menu, or clicking the tray icon, SHALL restore and focus the app's existing window. The app SHALL NOT create a second window; if the window is already visible, it SHALL simply gain focus.

#### Scenario: Show restores a hidden window

- **GIVEN** the main window is hidden after being closed
- **WHEN** the user selects "Show robot-notes" from the tray menu
- **THEN** the same window SHALL become visible and gain focus, and no additional window SHALL be created

#### Scenario: Show focuses an already-visible window

- **GIVEN** the main window is currently visible but not focused
- **WHEN** the user clicks the tray icon
- **THEN** the window SHALL gain focus and no additional window SHALL be created

### Requirement: Tray menu can fully quit the app

Selecting "Quit" from the tray menu SHALL terminate the app process, closing any open WebSocket connections and ending background operation.

#### Scenario: Quit ends the process

- **GIVEN** the app is running on macOS, with or without its window visible
- **WHEN** the user selects "Quit" from the tray menu
- **THEN** the app process SHALL terminate and the menu-bar icon SHALL disappear
