## ADDED Requirements

### Requirement: Platform-aware notes motion
The client SHALL use Cupertino page navigation on iOS, Material navigation on Android, and brief stationary fades for compact desktop notes navigation. Split-view note selection SHALL have no route animation.

#### Scenario: Selecting a note in a split view
- **WHEN** a user selects a note beside the visible notes list
- **THEN** the detail pane changes without a route animation

#### Scenario: Mobile notes navigation
- **WHEN** a user opens or closes a note on a compact mobile layout
- **THEN** navigation uses the host platform's page transition and back behavior

### Requirement: Platform-aware vault dialog motion
Vault creation and rename dialogs SHALL use Cupertino dialog motion on iOS, Material dialog motion on Android, and brief fades on desktop.

#### Scenario: Opening a vault dialog
- **WHEN** a user opens Create vault or Rename vault
- **THEN** the dialog uses the platform-appropriate presentation

### Requirement: Reduced motion for notes and vault dialogs
The client SHALL omit notes route and vault dialog animations when the system requests reduced motion.

#### Scenario: Reduced motion is enabled
- **WHEN** a user navigates to a note or opens a vault dialog with reduced motion enabled
- **THEN** the transition completes without animation
