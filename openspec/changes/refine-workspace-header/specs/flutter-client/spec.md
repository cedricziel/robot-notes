## ADDED Requirements

### Requirement: Compact platform-aware workspace header
The authenticated workspace SHALL reserve the system top inset once, above the connection banner and vault selector. The vault selector SHALL use a bounded menu trigger with an ellipsized name instead of a full-width underlined field. Vault creation and renaming SHALL use Cupertino dialog controls on Apple platforms and Material dialog controls elsewhere.

#### Scenario: Connected workspace with a system inset
- **WHEN** the workspace has a status bar or macOS title-bar inset
- **THEN** the vault selector and routed content do not each add the same inset

#### Scenario: Manage a vault on Apple platforms
- **WHEN** the user creates or renames a vault on macOS or iOS
- **THEN** the app presents Cupertino text input and dialog actions
- **AND** the existing permissions and API operations are preserved

#### Scenario: Long vault name on a narrow window
- **WHEN** the selected vault name exceeds the available width
- **THEN** the name is ellipsized and the management controls remain reachable

#### Scenario: Open vault controls in the authenticated app
- **WHEN** the user opens a vault menu or management dialog
- **THEN** the controls have access to the route navigator and overlay
- **AND** selecting another vault returns to the notes home route
