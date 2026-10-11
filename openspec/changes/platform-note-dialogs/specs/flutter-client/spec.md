## ADDED Requirements

### Requirement: Platform-aware note operation dialogs
Folder creation, note movement, and note deletion dialogs SHALL use the shared platform-specific dialog presentation policy and honor reduced motion.

#### Scenario: Opening an operation dialog
- **WHEN** a user creates a folder, moves a note, or requests note deletion
- **THEN** the dialog uses platform-appropriate motion and adaptive controls

#### Scenario: Reduced motion enabled
- **WHEN** an operation dialog opens or closes with reduced motion enabled
- **THEN** the transition completes without animation

#### Scenario: Cancelling a destructive action
- **WHEN** a user cancels note deletion
- **THEN** the note remains unchanged
