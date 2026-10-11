## ADDED Requirements

### Requirement: Platform-aware note and vault menus
The note More menu and vault switcher SHALL use compact anchored menus on desktop, action sheets on iOS, and Material popups on other platforms. Desktop menus SHALL support keyboard selection and Escape dismissal.

#### Scenario: Keyboard menu selection
- **WHEN** a desktop user opens the note More menu and selects an action with arrow keys and Enter
- **THEN** the action runs once and the menu closes

#### Scenario: Dismissing a desktop menu
- **WHEN** a user presses Escape in an open desktop menu
- **THEN** the menu closes without running an action

#### Scenario: Switching vaults
- **WHEN** a user opens the vault menu
- **THEN** the current vault is indicated and selecting another vault switches to it
