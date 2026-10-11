## ADDED Requirements

### Requirement: Platform-aware action feedback
Save, move, delete, and upload results SHALL use compact notifications on desktop, inline status bars on iOS, and native snackbars on Android and Fuchsia. Feedback SHALL announce results accessibly, support dismissal, and respect reduced motion.

#### Scenario: Successful note action
- **WHEN** a user saves, moves, or deletes a note
- **THEN** the result appears with the platform feedback style, including after deletion closes the note

#### Scenario: Upload result
- **WHEN** a file upload succeeds or fails
- **THEN** feedback reports the stored filename or error

#### Scenario: Repeated results
- **WHEN** another result arrives while feedback is visible
- **THEN** the latest result replaces the earlier message

#### Scenario: Reduced motion
- **WHEN** animations are disabled
- **THEN** result feedback appears and disappears without transitions
