## Context

See proposal.md for motivation. The Flutter app already provides adaptive menus, platform glyphs, theme surfaces, EmptyState, and ErrorStrip. Existing-note review verifies SHA-256 hashes and UTF-16 block offsets; decisions use record_revision.

## Goals / Non-Goals

Preserve API authorization and verified accepted content while reducing navigation. Keep policy, block authoring, and history in their existing note-level screen.

## Decisions

- Keep selection and draft state above the responsive layout. At 1000 logical pixels, show a 340-pixel inbox beside review; below that, replace the inbox with review and provide back navigation. Avoid separate routes for each size because resizing would otherwise lose draft state.
- Add a dedicated proposal review widget that loads one proposal and its accepted targets. Reuse the existing proposal content presentation with the note-level review entry point. Retain the current dialog wrapper there to bound this change.
- Show changes and evidence in a scrollable reading area, with inline discussion and wrapping actions. Use existing theme typography and surfaces instead of a new design system.
- Keep mutation failures inside review, preserve the composer draft, and refresh on conflicts. Refresh the inbox after successful actions without discarding selection.

## Risks / Trade-offs

- Concurrent selection or refresh requests may complete out of order. Use generation guards and key review state by proposal identity.
- Long source identifiers and narrow screens may overflow. Wrap metadata, constrain reading width, and test phone and desktop layouts with larger text.
- Archived proposals may reference removed notes. Permit read-only review without requiring accepted targets when no decision is allowed.

## Migration Plan

No data migration or API changes. Deploy with the Flutter client; revert the client change to restore previous navigation.
