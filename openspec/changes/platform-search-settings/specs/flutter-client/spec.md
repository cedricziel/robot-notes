## ADDED Requirements

### Requirement: Platform-aware search and settings overlays
The client SHALL present compact mobile search and settings overlays as Cupertino sheets on iOS and Material bottom sheets on Android. Desktop search and settings SHALL use dialogs regardless of window width.

#### Scenario: Dismissing compact search
- **WHEN** a user closes or drags away the native search sheet
- **THEN** the existing notes list is revealed without refetching it

#### Scenario: Narrow desktop window
- **WHEN** a desktop user opens search or settings in a narrow window
- **THEN** the client presents a dialog rather than a mobile sheet

### Requirement: Reduced motion for overlays
Search, settings, and disconnect confirmation SHALL honor the system reduced-motion preference.

#### Scenario: Reduced motion enabled
- **WHEN** a user opens or closes an overlay with reduced motion enabled
- **THEN** the route transition completes without animation
