## Context

Search is currently its own `GoRoute` (`/search`), pushed via `context.push('/search')` from the notes list's AppBar search icon and its narrow-layout bottom nav item. `_SearchRoutePage` owns a `NotesSearchController` scoped to the route's lifetime. See proposal.md - Why.

## Goals / Non-Goals

**Goals:**

- Keep the list mounted underneath search so closing it never re-fetches.
- Give the empty (pre-query) state real content instead of a static hint.

**Non-Goals:**

- No change to `NotesSearchController` or the query/results pipeline itself.
- No change to how a search result is opened (`onResultTap` still pushes `/notes/{id}`).

## Decisions

- **Overlay via `showGeneralDialog`, not a route.** A GoRoute makes search independently deep-linkable, but nothing in the product needs to link directly into an empty search box, and a route replaces the screen behind it in the navigation stack (losing scroll position, forcing a rebuild on return). `showGeneralDialog` keeps the list widget alive underneath, gives a scrim for free, and is dismissible by tapping outside or the back gesture without extra plumbing. Alternative considered: a `Navigator` sub-route via a nested `Overlay` — more code for the same effect `showGeneralDialog` already gives.
- **`NotesSearchController` scoped to the dialog call, not to `AppSession`.** Search is transient and query-heavy; keeping a controller alive for the app's lifetime buys nothing and would leak stale results into the next open. It's created in `_openSearch` and disposed in a `finally` once the dialog closes, mirroring the old per-route ownership.
- **Recent notes come from `session.list.value.items`, not a new fetch.** The notes list controller already holds the most-recently-updated-first page in memory; passing it straight into `SearchScreen.recentNotes` avoids a second round trip and keeps the two lists trivially consistent.

## Risks / Trade-offs

- [Search is no longer bookmarkable as a URL] → Accepted: nothing in the review or the product asked for a shareable search URL, and the overlay reachable from every screen's search affordance is strictly easier to get to than typing a URL.
- [`recentNotes` reflects whatever folder/filter the list is currently scoped to, not a global "recent" view] → Acceptable for a quick jumping-off point; the search results themselves are unscoped once the user types.
