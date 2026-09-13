## Why

Search today is a full-page `GoRoute` (`/search`): opening it replaces the notes list on screen, and it always opens to a blank "Type to search." state even though the user's own notes list already knows what they last worked on. A UX review of the search screen recommended presenting search as an overlay above the current screen (so the underlying list isn't lost) and seeding the empty state with recently-updated notes so search is useful before the user types anything.

## What Changes

- Search opens as an in-place overlay (`showGeneralDialog`, top-anchored sheet with a scrim, dismissible by tapping the scrim or the back gesture) instead of navigating to a full-page `/search` route. The underlying screen stays mounted underneath — no refetch when search closes.
- **BREAKING**: the `/search` route is removed; search is no longer independently deep-linkable by URL.
- Before the user types a query, the search view shows a "Recent" section listing recently-updated notes (reusing the already-loaded notes list, most-recently-updated-first) instead of a bare "Type to search." hint. The plain hint remains the fallback when there are no notes yet.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `flutter-client`: the search view requirement gains a "Recent" pre-query state; the routing requirement drops the `/search` route and its deep-link scenario, and the "tapping a search result" scenario is reframed around the overlay rather than a route.

## Impact

- `app/lib/src/search/search_screen.dart`: new `recentNotes` param and `_RecentSection` widget.
- `app/lib/src/app_router.dart`: removes the `/search` `GoRoute` and the `_SearchRoutePage` it used; adds `_openSearch` opening the overlay from the notes list's search affordances (AppBar action and, on narrow layouts, the bottom nav).

## Non-goals

- No change to how search queries or results are fetched/rendered (debounce, snippets, match count, error handling all stay as they are).
- No change to the notes list, note detail, or edit-mode screens beyond wiring their existing "open search" calls to the new overlay instead of a route push.
