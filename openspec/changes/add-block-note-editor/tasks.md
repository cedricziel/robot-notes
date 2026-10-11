## 1. Editor compatibility gate

Each task is a maximum 15-minute work unit. Split a task before starting if it exceeds that limit. For each behavior, first demonstrate a failing test, then implement the smallest passing change. Commit each coherent passing slice with a conventional commit message.

- [x] 1.1 Record candidate editor support for the project's Flutter targets and dependency constraints.
- [x] 1.2 Check a candidate's multi-block selection and undo in a minimal isolated example.
- [x] 1.3 Check composition input and software keyboard behavior in that example.
- [x] 1.4 Check keyboard navigation, screen-reader labels, and touch actions.
- [x] 1.5 Verify that the candidate permits source-span retention and opaque blocks.
- [x] 1.6 Check that editor controls and overlays can use the existing adaptive widgets and platform motion policies.
- [x] 1.7 Record reusable adaptive-widget gaps and assess local shared extensions or upstream contributions.
- [x] 1.8 Record the engine decision and evidence in design.md; stop integration if the gate fails.
- [x] 1.9 Add failing accessibility regressions for functional text replacement, cross-block selection, structural newlines, formatting retention, and read-only behavior.
- [x] 1.10 Implement accessibility actions through the editor transaction pipeline and pass the regressions.
- [x] 1.11 Bridge standalone themes into the editor subtree and verify theme updates without changing surrounding controls.
- [x] 1.12 Run the full compatibility gate through the reusable integration layer, including composition and opaque-source preservation.
- [x] 1.13 Record the adopted engine, integration boundaries, and gate evidence before continuing the adapter.

Gate outcome: **passed** through the reusable adaptive_super_editor integration layer. All nine compatibility probes pass, with additional accessibility, theme, and preservation regressions. See design.md and tool/editor_compatibility/README.md. Native target and assistive-technology validation remain outstanding.

## 2. Markdown document adapter

- [x] 2.1 Add failing no-op round-trip fixtures for supported block types.
- [x] 2.2 Add failing preservation fixtures for tables, nested lists, references, images, wiki links, and embeds.
- [x] 2.3 Add the session document model with original source spans and transient identities.
- [x] 2.4 Parse paragraphs and headings with source retention.
- [x] 2.5 Parse flat lists and checkboxes with source retention.
- [x] 2.6 Parse quotes, fenced code, and dividers with source retention.
- [x] 2.7 Preserve unsupported regions and fall back to source on unsafe conversion.
- [x] 2.8 Add failing adjacent-block boundary tests for edits, moves, and deletions.
- [x] 2.9 Serialize changed blocks while reusing untouched source spans.
- [x] 2.10 Pass round-trip fixtures and commit the adapter slice.

## 3. Block document interactions

- [x] 3.1 Add failing tests for paragraph split, merge, and final-block deletion.
- [x] 3.2 Implement paragraph split, merge, and final-block behavior.
- [x] 3.3 Add failing tests for list continuation, list exit, checkboxes, and literal code newlines.
- [x] 3.4 Implement list continuation and exit.
- [x] 3.5 Implement checkbox and code newline behavior.
- [x] 3.6 Add failing tests for slash insertion, labelled insertion, and Escape dismissal.
- [x] 3.7 Implement slash insertion and menu dismissal.
- [x] 3.8 Implement labelled insertion and safe block conversion.
- [x] 3.9 Add failing tests for reorder, deletion, focus retention, and destructive conversion guards.
- [x] 3.10 Implement move actions and deletion.
- [x] 3.11 Implement drag reordering and focus retention.
- [x] 3.12 Add failing tests for inline formatting, links, and platform shortcuts.
- [x] 3.13 Implement bold, italic, and inline code actions.
- [x] 3.14 Implement links and formatting shortcuts while preserving wiki-link behavior.
- [x] 3.15 Verify undo and redo for both text and structural changes with regression tests.
- [x] 3.16 Verify multi-block copy, replacement, deletion, and paste with regression tests.
- [x] 3.17 Add opaque-block source actions and preserve existing database embed rendering.
- [x] 3.18 Verify labelled touch and keyboard actions, then commit the interaction slice.

- [x] 3.19 Add failing platform-theme tests for editor menus and link dialogs.
- [x] 3.20 Integrate editor actions with shared adaptive controls; keep note-specific behavior in the editor.
- [x] 3.21 Add failing text-scaling, reduced-motion, and narrow-desktop tests for editor overlays.
- [x] 3.22 Make editor overlays pass the adaptive presentation tests.
- [x] 3.23 For demonstrated shared-widget gaps, document a bounded contribution with ownership and regression coverage; record when no contribution is needed.

## 4. Note screen and persistence integration

- [x] 4.1 Add failing tests for automatic lock acquisition and existing-note focus behavior.
- [x] 4.2 Enter editing automatically after acquisition and re-fetch; preserve new-note title selection.
- [x] 4.3 Add failing tests for failed acquisition, retry, and closing during acquisition.
- [x] 4.4 Implement read-only fallback and retry without leaking locks.
- [x] 4.5 Add failing tests for dirty source switching and no-op switching without saves.
- [x] 4.6 Connect the block document and source option to one controller draft.
- [x] 4.7 Implement conversion failure feedback without losing source.
- [x] 4.8 Add failing tests for structural autosave, explicit save, and close flush.
- [x] 4.9 Route block mutations through the existing save lifecycle.
- [x] 4.10 Add failing tests for save completion during typing and composition.
- [x] 4.11 Preserve newer edits and selection when save acknowledgements arrive.
- [x] 4.12 Add failing tests for conflict reconciliation and lock loss in both presentations.
- [x] 4.13 Retain complete Markdown drafts through conflict and lock-loss recovery.
- [x] 4.14 Update source-editor assumptions in screen tests and commit the integration slice.

## 5. Definition of Done

- [x] 5.1 Run relevant formatting, analyzer, and adapter tests.
- [x] 5.2 Run note controller and editor widget regression tests.
- [x] 5.3 Use verify-project-local to start an isolated server and real app.
- [x] 5.4 Verify block editing, source switching, saving, and reopening against that instance.
- [x] 5.5 Verify lock contention and conflict recovery against that instance.
- [x] 5.6 Verify touch, keyboard, composition, and accessibility behavior on available targets; record unverified targets.
- [x] 5.7 Inspect stored Markdown for unchanged unsupported content and absent editor metadata.
- [x] 5.8 Clean up the isolated instance and record validation evidence.
- [x] 5.9 Verify adaptive presentation under Apple and Material platform themes, text scaling, reduced motion, and narrow desktop layouts.
- [x] 5.10 Validate the OpenSpec change with --strict and confirm that each requirement has coverage or recorded manual evidence.


## 6. Editor layout feedback

Follow-up complete.

- [x] 6.1 Add regressions for natural table width and horizontal overflow.
- [x] 6.2 Align block gutters and use the available editing width.
- [x] 6.3 Keep tables at their natural width inside horizontal scrollers.
- [x] 6.4 Verify phone and desktop layouts and record the results.

- [x] 6.5 Remove simultaneous source previews and verify one source pane across widths.
- [x] 6.6 Align checkbox graphics with the content edge without losing editing or accessibility behavior.
- [x] 6.7 Match block typography and authoring fields to the application rendering style.


## 7. Presentation selector polish

Follow-up complete.

- [x] 7.1 Replace floating mode buttons with a grouped selector and a non-wrapping toolbar.
- [x] 7.2 Verify source switching, narrow widths, and platform presentation.
- [x] 7.3 Check the real browser layout and record the result.
