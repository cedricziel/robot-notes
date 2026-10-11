## Context

See [proposal.md](proposal.md) for motivation and scope. The note screen keeps one Markdown draft across block and source presentations. `NoteController.enterEditMode()` acquires the note lock, re-fetches the note, and starts heartbeats. Its edit buffers feed debounced autosave and version conflict handling. The storage specification makes Markdown files canonical.

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

### Compatibility gate result and engine choice

The October 11, 2026 probes in [tool/editor_compatibility](../../../tool/editor_compatibility/README.md) evaluated Super Editor 0.3.0-dev.52 and Flutter Quill 11.6.0 on Flutter 3.47.6 with Dart 3.13.5. The focused Super Editor gate now passes with the local `adaptive_super_editor` package. Exact CI Flutter 3.47.2 and native target validation remain outstanding.

Super Editor passed the editor interaction checks for cross-block deletion and undo, opaque source retention, keyboard navigation, shared action menus, link dialogs, and composition across a host rebuild. The local package supplies a narrow bridge around Super Editor. `AdaptiveSuperEditor` projects document state into editable-text semantics and routes focus, text replacement, selection updates, and cursor movement into the editor pipeline. `SuperEditorThemeBridge` projects the standalone Material and Cupertino themes into Super Editor's legacy Flutter theme lookups while preserving inherited text scaling and reduced-motion settings.

Widget tests verify text and focus semantics, selections across blocks, text replacement with undo, character movement across emoji boundaries, formatting and opaque-source preservation, and read-only behavior. The fixed gate log records nine passing checks, and the local package has 46 passing tests. These tests prove the widget contract; they do not prove VoiceOver or TalkBack behavior on a native device.

Real web verification found that Flutter 3.47.6's semantics text-editing strategy omits the `beforeinput` listener needed to populate insertion deltas. Direct block typing with web accessibility enabled therefore produced selection updates without text edits. The local bridge configures web input with `enableDeltaModel: false` and uses Super Editor's public `imeOverrides` hook to convert complete values into minimal document deltas. Native input retains the default delta configuration. The adapter preserves composition, formatting, emoji boundaries, and undo through the existing editor pipeline; keyboard brightness follows the adaptive theme.

The rebuilt web app against a throwaway local server now accepts direct block typing with accessibility enabled: the paragraph changes, the draft becomes dirty, and the focused accessibility input value updates. Native screen-reader behavior, physical software keyboards, the remaining browser accessibility interactions, and Android, iOS, Linux, and Windows runtime behavior remain platform validation targets.

Flutter Quill completed six passing checks and three failing adoption checks. Its custom embeds retain opaque source, and cross-block undo, keyboard navigation, and shared menu interactions pass. It has the theme and editable-semantics failures found before remediation. Composition survives a host rebuild, but removing the editor during active composition triggers a callback into a defunct element. Adopt Super Editor 0.3.0-dev.52 with the local bridge; do not add Flutter Quill.

The probes use separate packages and lockfiles. The compatibility gate includes semantics and theme checks, so baseline-only passes do not establish adoption. Original Markdown preservation is demonstrated for an opaque region beside an edited paragraph. The production parser and serializer have separate round-trip fixtures; the isolated opaque-source probes do not cover their complete behavior.

### Adaptive integration ownership

The compatibility widgets verify that `AdaptiveMoreMenu` opens and dismisses through touch and that `showPlatformDialog`, `adaptiveDialogAction`, and `AdaptiveDialogTextField` work above the mounted editor. The local `adaptive_super_editor` package contains the Super Editor theme bridge and the document's functional editable-text semantics. It does not move document parsing, block operations, or note persistence into the adaptive host layer.

No contribution to `material_ui` or `cupertino_ui` is currently needed. The probes show that the existing host controls and presentation policies integrate with Super Editor through the local bridge. A cursor-anchored slash menu or selection toolbar may need editor-specific work; defer any shared control until app integration demonstrates a reusable host behavior and a tested gap.

The existing `notesPage` motion helper had a shared lifecycle defect: crossing the large layout breakpoint changed the `Page` type and remounted the note controller. A dirty draft could disappear before autosave. Keep each platform's page type stable while updating transition durations for split views and reduced motion. Desktop pages remain `CustomTransitionPage`; native pages retain Material or Cupertino routes, including iOS swipe-back. This bounded local helper improvement belongs to `app/lib/src/widgets/platform_motion.dart`. Router regressions preserve the same controller, dirty source buffer, and acquired lock across both resize directions with macOS, iOS, and Android theme overrides. Motion and swipe-back tests cover the route policy; these widget variants are not native device validation.

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


## Implementation validation

Validated on October 11, 2026, using Flutter 3.47.6 and Dart 3.13.5 on macOS:

- The complete Super Editor compatibility gate passes all nine tests.
- The reusable editor package passes all 46 tests, including Markdown preservation, accessibility actions, adaptive themes, composition, Unicode, and complete-value web input.
- The app passes all 955 tests. Analyzer and formatting checks pass through the repository commit hooks.
- The release web client builds successfully.
- The real web app connected through its setup flow to a disposable loopback server with separate HTTP and VM-service ports, isolated data, a temporary API key, and telemetry disabled. Direct block typing, checkbox autosave, source switching, explicit saving, reopening, lock contention and retry, and conflict recovery were exercised. API reads confirmed the saved Markdown and unchanged unsupported table source through version 8.
- Browser layouts were checked at 390×844, 844×390, 768×1024, 1024×768, and 1440×900. An unsaved block draft survived crossing the desktop breakpoint and persisted afterward. Browser logs contained no errors or warnings.
- The verification tab was closed, its viewport override reset, the server stopped, and disposable data and credentials removed.

Native VoiceOver and TalkBack, physical software keyboards and composition, and native Android, iOS, macOS, Linux, and Windows runtimes remain unverified. Platform-theme widget variants do not establish native device coverage. The exact Flutter 3.47.2 CI toolchain also remains unverified locally. These limits do not change the passing widget compatibility gate or the observed web workflow.


## Editor layout feedback

The authoring document uses the available pane width with a 16px outer inset, a 28px drag gutter, and a 48px action gutter. All block models share these constraints. Drag handles align with the first text line; checkboxes start at the content edge. The local task component delegates text composition, selection, underlines, and undo behavior to Super Editor's public text component, while retaining accessible completion controls and read-only behavior.

Block typography uses the application's Markdown styles. Authoring fields have flat decoration. Tables use intrinsic column widths and left-aligned headings. The Markdown renderer's existing horizontal scroller bounds wide tables; small tables keep their natural width.

Markdown source uses one full-width editing pane without a simultaneous preview. Switching to Blocks supplies the rendered presentation, including database embeds. Source formatting and wiki-link completion remain available.

The follow-up passes 160 focused block, screen, and theme tests and all 955 app tests. New regressions cover handle geometry, checkbox alignment and undo, natural table sizing and horizontal scroll, and single-pane source layouts at desktop, phone portrait, and phone landscape widths. Real browser checks use 390×844, 844×390, and 1440×900 layouts. Portrait and landscape checks confirm that source and block content remain scrollable to the end of the note. A real checkbox edit persisted while both table sources remained byte-for-byte unchanged. Browser logs contained no errors or warnings. The verification tab was closed, its viewport reset, and the disposable server and data cleaned up. Native mobile runtime validation remains outside this browser check.


### Stable presentation selector

Blocks and Markdown source use one grouped selector aligned to the editor's outer inset. Apple themes use a Cupertino sliding segmented control; Material themes use a segmented button. Formatting actions occupy a separate horizontal scroller in the same toolbar row. Narrow widths and larger text put that action row below the selector without wrapping individual actions around it. Switching presentations leaves the selector anchored.

The selector follow-up passes 140 editor and screen tests, including phone toolbar geometry and 2× text scaling under Apple and Material themes. The rebuilt web app was checked at 390×844 and 844×390. Formatting actions scroll, both presentations remain reachable, and source switching leaves the stored note unchanged at version 1. Browser logs contain no errors or warnings. The temporary browser, viewport override, server, data, and credentials were cleaned up.
