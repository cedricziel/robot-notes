## ADDED Requirements

### Requirement: Platform-aware appearance selection
The Appearance chooser SHALL display System, Light, and Dark as Cupertino segments on Apple platforms and a Material dropdown elsewhere, using the same saved preference.

#### Scenario: Selecting an Apple appearance segment
- **WHEN** a user selects Dark, Light, or System
- **THEN** the selected segment and saved theme preference update

#### Scenario: Restoring the appearance preference
- **WHEN** preferences load after selecting an appearance mode
- **THEN** the selected mode remains the saved choice
