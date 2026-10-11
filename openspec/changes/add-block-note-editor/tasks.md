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

Gate outcome: **failed**. Completing the checks records evidence; it does not mean a candidate passed. See design.md and tool/editor_compatibility/README.md. Native target and assistive-technology validation remain outstanding. Task group 2 is blocked until editable-text semantics and adaptive theme integration pass the full compatibility probe.

## 2. Markdown document adapter

- [ ] 2.1 Add failing no-op round-trip fixtures for supported block types.
- [ ] 2.2 Add failing preservation fixtures for tables, nested lists, references, images, wiki links, and embeds.
- [ ] 2.3 Add the session document model with original source spans and transient identities.
- [ ] 2.4 Parse paragraphs and headings with source retention.
- [ ] 2.5 Parse flat lists and checkboxes with source retention.
- [ ] 2.6 Parse quotes, fenced code, and dividers with source retention.
- [ ] 2.7 Preserve unsupported regions and fall back to source on unsafe conversion.
- [ ] 2.8 Add failing adjacent-block boundary tests for edits, moves, and deletions.
- [ ] 2.9 Serialize changed blocks while reusing untouched source spans.
- [ ] 2.10 Pass round-trip fixtures and commit the adapter slice.

## 3. Block document interactions

- [ ] 3.1 Add failing tests for paragraph split, merge, and final-block deletion.
- [ ] 3.2 Implement paragraph split, merge, and final-block behavior.
- [ ] 3.3 Add failing tests for list continuation, list exit, checkboxes, and literal code newlines.
- [ ] 3.4 Implement list continuation and exit.
- [ ] 3.5 Implement checkbox and code newline behavior.
- [ ] 3.6 Add failing tests for slash insertion, labelled insertion, and Escape dismissal.
- [ ] 3.7 Implement slash insertion and menu dismissal.
- [ ] 3.8 Implement labelled insertion and safe block conversion.
- [ ] 3.9 Add failing tests for reorder, deletion, focus retention, and destructive conversion guards.
- [ ] 3.10 Implement move actions and deletion.
- [ ] 3.11 Implement drag reordering and focus retention.
- [ ] 3.12 Add failing tests for inline formatting, links, and platform shortcuts.
- [ ] 3.13 Implement bold, italic, and inline code actions.
- [ ] 3.14 Implement links and formatting shortcuts while preserving wiki-link behavior.
- [ ] 3.15 Verify undo and redo for both text and structural changes with regression tests.
- [ ] 3.16 Verify multi-block copy, replacement, deletion, and paste with regression tests.
- [ ] 3.17 Add opaque-block source actions and preserve existing database embed rendering.
- [ ] 3.18 Verify labelled touch and keyboard actions, then commit the interaction slice.

- [ ] 3.19 Add failing platform-theme tests for editor menus and link dialogs.
- [ ] 3.20 Integrate editor actions with shared adaptive controls; keep note-specific behavior in the editor.
- [ ] 3.21 Add failing text-scaling, reduced-motion, and narrow-desktop tests for editor overlays.
- [ ] 3.22 Make editor overlays pass the adaptive presentation tests.
- [ ] 3.23 For demonstrated shared-widget gaps, document a bounded contribution with ownership and regression coverage; record when no contribution is needed.

## 4. Note screen and persistence integration

- [ ] 4.1 Add failing tests for automatic lock acquisition and existing-note focus behavior.
- [ ] 4.2 Enter editing automatically after acquisition and re-fetch; preserve new-note title selection.
- [ ] 4.3 Add failing tests for failed acquisition, retry, and closing during acquisition.
- [ ] 4.4 Implement read-only fallback and retry without leaking locks.
- [ ] 4.5 Add failing tests for dirty source switching and no-op switching without saves.
- [ ] 4.6 Connect the block document and source option to one controller draft.
- [ ] 4.7 Implement conversion failure feedback without losing source.
- [ ] 4.8 Add failing tests for structural autosave, explicit save, and close flush.
- [ ] 4.9 Route block mutations through the existing save lifecycle.
- [ ] 4.10 Add failing tests for save completion during typing and composition.
- [ ] 4.11 Preserve newer edits and selection when save acknowledgements arrive.
- [ ] 4.12 Add failing tests for conflict reconciliation and lock loss in both presentations.
- [ ] 4.13 Retain complete Markdown drafts through conflict and lock-loss recovery.
- [ ] 4.14 Update source-editor assumptions in screen tests and commit the integration slice.

## 5. Definition of Done

- [ ] 5.1 Run relevant formatting, analyzer, and adapter tests.
- [ ] 5.2 Run note controller and editor widget regression tests.
- [ ] 5.3 Use verify-project-local to start an isolated server and real app.
- [ ] 5.4 Verify block editing, source switching, saving, and reopening against that instance.
- [ ] 5.5 Verify lock contention and conflict recovery against that instance.
- [ ] 5.6 Verify touch, keyboard, composition, and accessibility behavior on available targets; record unverified targets.
- [ ] 5.7 Inspect stored Markdown for unchanged unsupported content and absent editor metadata.
- [ ] 5.8 Clean up the isolated instance and record validation evidence.
- [ ] 5.9 Verify adaptive presentation under Apple and Material platform themes, text scaling, reduced motion, and narrow desktop layouts.
- [ ] 5.10 Validate the OpenSpec change with --strict and confirm that each requirement has coverage or recorded manual evidence.
