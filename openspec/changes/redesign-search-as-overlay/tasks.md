## 1. Recent section

- [x] 1.1 Add `recentNotes` param and `_RecentSection` widget to `SearchScreen`, shown before the user types; fall back to the existing hint when empty
- [x] 1.2 Tests: Recent section shows before typing, tapping a recent note calls `onResultTap`, empty `recentNotes` falls back to the hint, typing replaces the section

## 2. Overlay presentation

- [x] 2.1 Remove the `/search` `GoRoute` and `_SearchRoutePage`/`_SearchRoutePageState`
- [x] 2.2 Add `_openSearch` opening `SearchScreen` via `showGeneralDialog` (scrim, top-anchored sheet, slide transition), scoping a fresh `NotesSearchController` to the call and disposing it on close
- [x] 2.3 Wire the notes list's AppBar search action and narrow-layout bottom nav search item to `_openSearch` instead of `context.push('/search')`
- [x] 2.4 Tests: opening search overlays the list without replacing it; closing the overlay (scrim tap) returns to the list without re-fetching

## 3. Verify

- [x] 3.1 `flutter test`, `flutter analyze`, `dart format` for the app
- [x] 3.2 `make test` / `make lint` / `make fmt` at the repo root
