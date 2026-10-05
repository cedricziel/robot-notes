## Visual direction

Match the approved concept through neutral opaque document surfaces, a muted
sidebar, indigo selection and restrained borders. Keep platform fonts and
existing native dialogs. Controls use small corner radii rather than pills.
Dark mode uses the same hierarchy with brighter accessible accent colors.

## Navigation

The compact root workspace has four real destinations. Notes keeps its folder
scope, databases lists registered definitions, search retains its controller,
and settings owns account/device preferences. Destinations initialize lazily
so hidden search never takes initial keyboard focus. Opening a note keeps the
existing guarded note route, avoiding a tab switch that bypasses dirty-edit
save handling. Cmd/Ctrl+K remains an overlay from any screen; on iOS it is a
bottom sheet with keyboard-aware height.

## Preferences

Appearance and sidebar width are device-local SharedPreferences values in an
InheritedNotifier. The root app rebuilds ThemeMode when the preference changes.
Test harnesses can omit the scope and retain previous defaults.

## Reading and editing

Move the property panel into the reading scroll so it cannot pin most of a
short phone screen. A stable GlobalKey reparents its existing state when edit
mode puts the panel above the editor. Lock, save and reconciliation behavior
are unchanged.

## Verification

Run client analysis and the client suite, including real destination navigation,
search keyboard selection, persistence, reader/property regressions, and Apple
control tests. Render actual widgets with seeded data for visual inspection.
