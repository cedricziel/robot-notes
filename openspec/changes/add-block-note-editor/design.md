## Context

See [proposal.md](proposal.md) for motivation and scope. The current `app/lib/src/notes/note_screen.dart` uses a text controller and Markdown preview. `NoteController.enterEditMode()` acquires the note lock, re-fetches the note, and starts heartbeats. Its edit buffers feed debounced autosave and version conflict handling. The storage specification makes Markdown files canonical.

## Goals / Non-Goals

The editor must preserve the existing persistence boundary while adding a document editing model. Selection, composition, undo, and source preservation are release criteria. Server-side block identities and changes to lock or note APIs are excluded. Unsupported content remains editable through source.

## Decisions

### Keep Markdown canonical and retain source spans

Introduce a client-side document adapter that parses supported blocks and retains original source spans for all blocks. Session-local block identities stabilize focus and selection through reorder operations. They are never written into Markdown or sent as new API fields.

Reuse original spans for unchanged blocks. Serialize changed blocks with a documented Markdown mapping and delimiters that preserve adjacent block meaning. Treat unsupported constructs as opaque source spans. If parsing cannot safely determine boundaries, retain the full draft in source mode rather than partially converting it. An ordinary parse-and-pretty-print pipeline is rejected because it can rewrite unrelated content.

### Use one editing session and two presentations

The block document and source field represent the same `NoteController` draft. Mode switching commits any active composition before conversion and keeps the lock, dirty state, and version baseline. Avoid rebuilding the document after each keystroke or save acknowledgement. Map the selection when possible, otherwise focus the corresponding block without opening the software keyboard automatically.

Evaluate a Flutter document editing component through a bounded compatibility spike before adding a dependency. Required checks include multi-block selection, undo, IME input, accessibility, all supported platforms, an adapter that retains opaque source, and integration with the app's adaptive controls and platform motion. Do not choose an engine merely because it exports Markdown. If no candidate passes, revise the implementation design before proceeding; the product requirements stay fixed.

Independent text fields per block are rejected as the default architecture because document selection, clipboard behavior, and undo would need separate implementations. A persisted JSON document is rejected because it changes the storage contract.

### Compose the editor with adaptive widgets

Treat adaptive compatibility as a non-functional acceptance criterion. The app currently uses `material_ui`, `cupertino_ui`, `app/lib/src/widgets/adaptive.dart`, and `app/lib/src/widgets/platform_motion.dart`. Reuse their controls and presentation policies for block menus, formatting actions, link dialogs, and source switching where suitable. Resolve platform behavior through the app's theme, and respect text scaling, focus, semantics, and reduced-motion settings.

The document engine must allow its toolbar, menus, dialogs, and selection controls to integrate with these policies. A fixed visual theme or hard-coded platform behavior is grounds to reject a candidate. Layout width determines available space, not platform identity; resizing a desktop window must not turn its controls into phone controls.

When integration reveals a missing general-purpose control or a defect, assess a small extension to the shared adaptive layer before adding an editor-local workaround. Keep document parsing, block operations, and note persistence outside that layer. Record whether each gap merits a local shared widget, a contribution to the underlying UI packages, or an editor-specific implementation. Potential upstream contributions are conditional on a demonstrated reusable need; publication and upstream acceptance are not v1 release requirements.

### Compatibility gate result

The October 11, 2026 probes in [tool/editor_compatibility](../../../tool/editor_compatibility/README.md) evaluated Super Editor 0.3.0-dev.52 and Flutter Quill 11.6.0 on Flutter 3.47.6 with Dart 3.13.5. Both resolve with the app's pinned standalone UI packages and compile. Upstream describes mobile, desktop, and web support, but this gate executed macOS-host widget tests only. Exact CI Flutter 3.47.2 and native target validation remain outstanding.

Super Editor completed seven passing checks and two failing adoption checks. Cross-block deletion and undo restore node identities, custom opaque nodes retain original source, arrow-key navigation works, shared action menus remain tappable, and delta IME composition survives a host rebuild. The standard text-field positive control exposes editable semantics. The mounted editor does not expose that role, and its legacy theme lookup does not inherit the standalone adaptive host's dark theme.

Flutter Quill completed six passing checks and three failing adoption checks. Its custom embeds retain opaque source and its cross-block undo, keyboard navigation, and shared menu interactions pass. It has the same semantics and theme failures. Composition survives a host rebuild, but removing the editor during active composition triggers a callback into a defunct element.

Decision: neither published candidate passes the gate, so no editor dependency is adopted and adapter or note-screen integration must not start. Super Editor is the provisional remediation candidate because its node model fits source identities and its simulated composition check passes. A bounded accessibility and theme-integration investigation must produce a passing full probe before task group 2 starts. A label-only semantics wrapper is insufficient; accessible text replacement and selection must reach the document editing pipeline while preserving opaque source.

The probes use separate packages and lockfiles. Their known failing tests carry the `compatibility_gate` tag. Baseline-only test passes do not satisfy adoption. No native software keyboard, native screen reader, browser build, or non-macOS runtime was verified. Original Markdown preservation is demonstrated for an opaque region beside an edited paragraph, not yet for a complete parser and serializer.

### Adaptive contribution assessment

The real `AdaptiveMoreMenu` mounts with both candidates and its actions can be opened and dismissed by tap. The real `showPlatformDialog`, `adaptiveDialogAction`, and `AdaptiveDialogTextField` also open and dismiss a basic link dialog above both mounted editors. Full editing-session focus, reduced-motion, and native-platform behavior remain later validation tasks.

The shared layer has no cursor-anchored command menu or formatting-selection toolbar. These are potential reusable controls, but an adopted engine's anchoring and selection APIs must demonstrate the need before adding abstractions. Keep slash commands and block mutations in the editor. Extend shared widgets only for general presentation behavior supported by regression tests.

The demonstrated theme-lookup mismatch is a candidate-engine integration concern. Assess a narrow theme bridge or migration to standalone UI imports in that engine. Editable-text semantics belong in the document engine, not in `AdaptiveMoreMenu`. No change or upstream contribution to `material_ui` or `cupertino_ui` is justified by these probes. Record those ownership boundaries before any contribution work.

### Enter editing through the existing lock lifecycle

After initial load, automatically enter the existing acquisition flow once per note opening. Until acquisition and re-fetch succeed, display read-only content. Failed acquisition offers retry. Opening a note therefore holds the exclusive lock even if the user only reads it; closing releases it through the existing flow. Keep this tradeoff explicit rather than adding an unrequested lock protocol.

Existing notes do not autofocus. New notes retain title selection. Use the existing debounce, explicit save, and close-flush paths. Preserve newer edits when a save completes. Conflicts continue to compare Markdown drafts. Escape first dismisses editor menus, then follows the existing close flow.

### Keep v1 authoring bounded

Provide the agreed flat block set, inline formatting, links, slash insertion, and accessible organization actions. Nested structures, tables, and images remain opaque. Existing database embeds use the current read-only rendering in an opaque block; source stays unchanged. Existing wiki-link behavior must remain available, and image URLs must not be fetched.

## Risks / Trade-offs

- Markdown boundary errors can corrupt unrelated content. Require round-trip fixtures covering references, whitespace, fences, nested lists, tables, wiki links, and embeds before UI integration.
- Automatic locking increases contention for readers. Preserve holder feedback and explicit retry; do not silently retry in a loop.
- Document engines can mishandle composition or selection. Gate dependency adoption on the compatibility spike and verify real keyboard and touch interactions.
- Existing screen tests assume raw source or an Edit action. Update those expectations while retaining save, close, conflict, and lock regression coverage.

## Migration Plan

No file or API migration is needed. Deliver adapter, editor interactions, and screen integration as small coherent commits. Keep the new editor disconnected until its persistence tests pass. Switching the UI back to the source editor is a rollback path because saved notes remain Markdown. Validate the complete workflow using the project's isolated local verification skill before release.
