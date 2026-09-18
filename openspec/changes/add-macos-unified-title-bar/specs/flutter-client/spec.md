## ADDED Requirements

### Requirement: macOS window uses a unified title bar

On the macOS desktop build the native window SHALL use a hidden (unified/transparent) title-bar style with the traffic-light buttons kept visible and no title text shown, set once at startup. The Flutter content tree SHALL receive a top inset of at least `kMacTitleBarInset` (28 logical pixels) via `MediaQuery.padding.top` wherever it is not already at least that large, so no app content renders under the traffic lights. A transparent strip spanning the full window width and that inset's height SHALL sit at the top of the content: a pan gesture on it SHALL start a native window drag, and a double-tap/double-click on it SHALL toggle the window between maximized and its previous size. Every other platform SHALL be unaffected: the title-bar style is never changed and no inset or strip is added.

#### Scenario: The window gets a unified title bar at startup

- **GIVEN** the app is launched on macOS
- **WHEN** startup runs
- **THEN** the native window SHALL be set to the hidden title-bar style with `windowButtonVisibility: true`
- **AND** on every other platform this SHALL NOT be attempted

#### Scenario: Content insets below the traffic lights

- **GIVEN** the app runs with a macOS theme
- **WHEN** any screen reads `MediaQuery.padding.top` (an `AppBar`, the `ConnectionBanner`, the three-pane shell's folder sidebar)
- **THEN** that value SHALL be at least `kMacTitleBarInset`, so the screen's own top-safe-area handling keeps its content clear of the traffic lights
- **AND** a screen that already reports a larger top padding SHALL keep that larger value rather than having it reduced

#### Scenario: The top strip drags and zooms the window

- **GIVEN** the app runs with a macOS theme
- **WHEN** the user starts a pan gesture on the transparent strip at the top of the window
- **THEN** the window SHALL begin a native drag, moving with the pointer
- **WHEN** the user double-taps or double-clicks the strip instead
- **THEN** the window SHALL toggle between maximized and its previous size
- **AND** on every other platform no such strip SHALL exist
