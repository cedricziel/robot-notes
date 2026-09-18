import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../desktop/app_menu_actions.dart';
import '../desktop/app_menu_bar.dart';
import '../format/note_time.dart';
import '../layout/breakpoints.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive.dart';
import '../widgets/status_strip.dart';
import 'link_autocomplete.dart';
import 'markdown_toolbar.dart';
import 'note_controller.dart';
import 'note_property_panel.dart';
import 'save_shortcut.dart';

/// How a [NoteScreen] is being shown, which decides what its leading
/// app-bar button means.
enum NotePresentation {
  /// Pushed over the notes list as its own route: the button goes back.
  page,

  /// The detail pane of the three-pane shell: the button clears the pane.
  pane,
}

/// Single-note view. Renders three modes off [NoteController]:
///
/// - viewing: rendered Markdown + presence/lock indicators.
/// - editing: title and content text fields, save / cancel actions.
/// - conflict: 409 reconcile UI showing both versions.
///
/// Locking is handled by the controller; this widget just dispatches.
class NoteScreen extends StatefulWidget {
  const NoteScreen({
    required this.controller,
    this.onClose,
    this.onOpenNote,
    this.onTagTap,
    this.startEditing = false,
    this.presentation = NotePresentation.page,
    @visibleForTesting this.installSaveShortcut = installWebSaveShortcut,
    @visibleForTesting this.linkAutocompleteScheduler,
    super.key,
  });

  final NoteController controller;
  final VoidCallback? onClose;

  /// Called when the user taps a backlink entry, with the referencing
  /// note's id. `null` renders the backlinks panel non-interactive.
  final ValueChanged<String>? onOpenNote;

  /// Called when the user taps a tag chip, with that tag. `null` renders
  /// the chips non-interactive.
  final ValueChanged<String>? onTagTap;

  /// Open straight into the editor with the title selected, so typing
  /// replaces a placeholder title.
  final bool startEditing;

  /// Whether this screen is its own route ([NotePresentation.page], the
  /// leading button reads "Back") or the detail pane of the three-pane
  /// shell ([NotePresentation.pane], it reads "Close"). Either way the
  /// button flushes a pending edit, releases the lock, and calls
  /// [onClose].
  final NotePresentation presentation;

  /// Overridable seam for tests: production code always uses
  /// [installWebSaveShortcut] (a no-op off web). Tests substitute a fake
  /// that captures the callback so they can invoke it directly, since the
  /// real one only ever fires from a live browser's `keydown` event.
  @visibleForTesting
  final VoidCallback Function(VoidCallback onSave) installSaveShortcut;

  /// Overridable seam for tests: production code debounces the `[[`-link
  /// title lookup with a real delay; tests substitute a synchronous one so
  /// they don't need to fake-advance a timer.
  @visibleForTesting
  final Future<void> Function(Duration)? linkAutocompleteScheduler;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  final TextEditingController _title = TextEditingController();
  late final _DiffTextController _content = _DiffTextController(_serverContent);
  late final LinkAutocompleteController _linkAutocomplete;

  /// The user's explicit choice for the editor's live preview, if they've
  /// made one this session. `null` means "whatever the width suggests":
  /// shown side-by-side at [WindowSizeClass.medium] and up, hidden on a
  /// compact window where it would halve an already small editor.
  bool? _previewOverride;

  String? _serverContent() {
    final s = widget.controller.value;
    if (s.mode != NoteMode.conflict) return null;
    return s.conflictCurrent?.content ?? '';
  }

  late final VoidCallback _uninstallWebSaveShortcut;

  /// The macOS menu bar's Note menu registry, when hosted under one.
  AppMenuActions? _menuActions;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncBuffersFromState);
    _linkAutocomplete = LinkAutocompleteController(
      search: widget.controller.searchLinkTitles,
      scheduler: widget.linkAutocompleteScheduler,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _open();
    });
    _uninstallWebSaveShortcut = widget.installSaveShortcut(_saveIfEditing);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _menuActions = AppMenuActionsScope.maybeOf(context);
    // Re-runs when this route stops or resumes being the current one, so
    // a note pushed over this one takes the Note menu with it and hands it
    // back on pop.
    _syncMenuActions();
  }

  @override
  void dispose() {
    _menuActions?.clearNote(this);
    widget.controller.removeListener(_syncBuffersFromState);
    _uninstallWebSaveShortcut();
    _title.dispose();
    _content.dispose();
    _linkAutocomplete.dispose();
    super.dispose();
  }

  void _onContentChanged(String value) {
    widget.controller.setEditContent(value);
    _linkAutocomplete.onChanged(value, _content.selection.baseOffset);
  }

  void _insertLink(String title) {
    final trigger = _linkAutocomplete.value.trigger;
    if (trigger == null) return;
    final result = insertLink(_content.text, trigger, title);
    _content.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.cursor),
    );
    widget.controller.setEditContent(result.text);
    _linkAutocomplete.close();
  }

  Future<void> _edit() async {
    await widget.controller.enterEditMode();
    _announceOutcome(failed: 'Could not start editing');
  }

  /// The raw `keydown` listener behind [installSaveShortcut] is attached to
  /// the browser `window`, not scoped to this widget's place in the
  /// Navigator stack — so with two note routes pushed, both screens' web
  /// listeners fire on the same keypress. Guard on [ModalRoute.isCurrent] so
  /// only the top-most note saves; a background note stays untouched, same
  /// as native `CallbackShortcuts` (which only fires for the focused route).
  void _saveIfEditing() {
    if (widget.controller.value.mode != NoteMode.editing) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    unawaited(_save());
  }

  Future<void> _save() async {
    await widget.controller.save();
    _announceOutcome(failed: 'Could not save', succeeded: 'Saved');
  }

  /// Wired to [NotePropertyPanel.onCommit]. Delegates to
  /// [NoteController.patchProperty], which never touches the title/content
  /// edit buffers (design.md), and reports success by comparing the note's
  /// version before and after — the controller's own [NoteState.error]
  /// field is not cleared on a successful patch, so it can't be read
  /// directly here without risking a stale error from an earlier,
  /// unrelated failure.
  Future<String?> _onPropertyCommit(String key, PropertyPatch patch) async {
    final before = widget.controller.value.note?.version;
    await widget.controller.patchProperty(set: patch.set, unset: patch.unset);
    if (!mounted) return null;
    final after = widget.controller.value;
    if (after.note?.version != before) return null;
    final error = after.error;
    return error == null ? null : _describe(error);
  }

  Future<void> _keepMine() async {
    await widget.controller.resolveConflictKeepMine();
    _announceOutcome(failed: 'Could not save', succeeded: 'Saved');
  }

  /// Snackbar for an outcome the state machine does not render itself.
  /// 409 (conflict view) and 423 (lock banner) already have their own UI.
  void _announceOutcome({required String failed, String? succeeded}) {
    if (!mounted) return;
    final s = widget.controller.value;
    final error = s.error;
    final String text;
    if (error == null) {
      if (succeeded == null) return;
      text = '$succeeded (v${s.note?.version})';
    } else if (error is LockedException || error is VersionConflictException) {
      return;
    } else {
      text = '$failed: ${_describe(error)}';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  static String _describe(ApiException e) =>
      e.message ?? 'HTTP ${e.statusCode}';

  Future<void> _open() async {
    if (!mounted) return;
    await widget.controller.open();
    if (!mounted || !widget.startEditing) return;
    await _edit();
    if (!mounted || widget.controller.value.mode != NoteMode.editing) return;
    // The title field mounts on the rebuild that follows the mode change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _title.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _title.text.length,
      );
    });
  }

  /// Sync the TextField contents whenever the controller's edit buffers
  /// change underneath us — e.g. after a save sets them to the server's
  /// latest, or after accepting the server side of a conflict.
  ///
  /// Every keystroke also flows through here (onChanged → controller →
  /// listener), so only assign when the field really differs: assigning
  /// `.text` resets the caret to the end, which mangles mid-text typing.
  void _syncBuffersFromState() {
    final s = widget.controller.value;
    _syncField(_title, s.editTitle);
    _syncField(_content, s.editContent);
    if (mounted) setState(() {});
    _syncMenuActions();
  }

  /// Publishes this note's commands to the macOS menu bar while this
  /// screen is the one in front, mirroring the app bar: Edit while
  /// viewing, Save while editing, Move/Delete only while viewing, Close
  /// whenever a note is loaded. Withdraws them while another route covers
  /// this one.
  void _syncMenuActions() {
    final actions = _menuActions;
    if (actions == null || !mounted) return;
    if (ModalRoute.of(context)?.isCurrent == false) {
      actions.clearNote(this);
      return;
    }
    final state = widget.controller.value;
    final loaded = state.note != null;
    final viewing = state.mode == NoteMode.viewing && loaded;
    final editing = state.mode == NoteMode.editing;
    actions.setNote(
      this,
      NoteMenuHandlers(
        edit: viewing ? _edit : null,
        save: editing ? _save : null,
        close: loaded ? _close : null,
        move: viewing ? _confirmMove : null,
        delete: viewing ? _confirmDelete : null,
      ),
    );
  }

  static void _syncField(TextEditingController field, String? buffer) {
    final next = buffer ?? '';
    if (field.text != next) field.text = next;
  }

  /// With autosave, there's nothing meaningful to confirm discarding —
  /// instead, a pending edit is flushed with an immediate save before
  /// leaving. Returns whether it's now safe to actually close: `false`
  /// keeps the note open, either because the flush landed on a conflict
  /// (the conflict view takes over) or because it failed with a plain
  /// error (edits stay intact, the existing error snackbar explains why).
  /// Losing the lock during the flush (423) still counts as safe to
  /// close — same as any other save that gets overtaken mid-edit.
  Future<bool> _flushPendingEdit() async {
    if (!widget.controller.value.isDirty) return true;
    widget.controller.cancelPendingAutosave();
    await widget.controller.save();
    if (!mounted) return false;
    final after = widget.controller.value;
    if (after.mode == NoteMode.conflict) return false;
    if (after.mode == NoteMode.editing && after.isDirty) {
      _announceOutcome(failed: 'Could not save');
      return false;
    }
    return true;
  }

  Future<void> _close() async {
    if (!await _flushPendingEdit()) return;
    await widget.controller.exitEditing();
    if (mounted) widget.onClose?.call();
  }

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (!didPop) await _close();
  }

  void _setPreviewShown(bool shown) {
    setState(() => _previewOverride = shown);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final note = state.note;
    final viewing = state.mode == NoteMode.viewing && note != null;
    final (
      IconData leadingIcon,
      String leadingTooltip,
    ) = switch (widget.presentation) {
      // A chevron on iOS/macOS, an arrow elsewhere.
      NotePresentation.page => (adaptiveBackIcon(context), 'Back'),
      NotePresentation.pane => (Icons.close, 'Close'),
    };
    return PopScope(
      canPop: !state.isDirty,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('note.close'),
            tooltip: leadingTooltip,
            icon: Icon(leadingIcon),
            onPressed: _close,
          ),
          title: Text(
            note?.title.isEmpty == true ? '(untitled)' : note?.title ?? '',
          ),
          actions: [
            if (state.viewers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: _PresenceAvatars(
                    key: const Key('note.presence'),
                    viewers: state.viewers,
                  ),
                ),
              ),
            if (viewing)
              IconButton(
                key: const Key('note.edit'),
                tooltip: 'Edit',
                icon: const Icon(Icons.edit),
                onPressed: _edit,
              ),
            if (state.mode == NoteMode.editing)
              TextButton(
                key: const Key('note.save'),
                onPressed: _save,
                child: const Text('Save'),
              ),
            if (viewing)
              AdaptiveMoreMenu(
                key: const Key('note.menu'),
                tooltip: 'More',
                entries: [
                  AdaptiveMenuEntry(
                    key: const Key('note.move'),
                    label: 'Move to folder…',
                    onSelected: _confirmMove,
                  ),
                  AdaptiveMenuEntry(
                    key: const Key('note.delete'),
                    label: 'Delete note',
                    destructive: true,
                    onSelected: _confirmDelete,
                  ),
                ],
              ),
          ],
        ),
        // On the macOS desktop build the native menu bar owns ⌘S and ⌘E
        // (see [withoutMenuOwnedShortcuts]); the Ctrl chords and Escape
        // stay here everywhere.
        body: CallbackShortcuts(
          bindings: withoutMenuOwnedShortcuts(<ShortcutActivator, VoidCallback>{
            if (state.mode == NoteMode.editing) ...{
              const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
              const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                  _save,
            },
            if (viewing) ...{
              const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _edit,
              const SingleActivator(LogicalKeyboardKey.keyE, control: true):
                  _edit,
            },
            const SingleActivator(LogicalKeyboardKey.escape): _close,
          }),
          child: _buildBody(context, state),
        ),
      ),
    );
  }

  /// Pull-to-refresh on the reading view: re-fetches the note and its
  /// backlinks. A failure is reported in a snackbar (the note stays);
  /// the controller ignores the pull outside viewing mode, so a pull that
  /// races the user into edit mode reports nothing.
  Future<void> _refresh() async {
    await widget.controller.reload();
    if (!mounted) return;
    final state = widget.controller.value;
    final error = state.error;
    if (state.mode != NoteMode.viewing || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not refresh the note: ${_describe(error)}'),
      ),
    );
  }

  /// Free-text folder path entry (see `design.md`'s note on this vs. a full
  /// tree picker). Prefills with the note's current folder so the user
  /// edits from there rather than retyping it.
  Future<void> _confirmMove() async {
    final note = widget.controller.value.note;
    if (note == null) return;
    // The field owns its own controller, so there's nothing to clean up
    // once the dialog closes.
    var draft = note.path;
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Move to folder'),
        content: AdaptiveDialogTextField(
          key: const Key('note.move.input'),
          initialValue: note.path,
          label: 'Folder path',
          hint: 'e.g. Projects/Alpha (blank for the vault root)',
          onChanged: (v) => draft = v,
        ),
        actions: [
          adaptiveDialogAction(
            ctx,
            key: const Key('note.move.cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          adaptiveDialogAction(
            ctx,
            key: const Key('note.move.confirm'),
            primary: true,
            onPressed: () => Navigator.of(ctx).pop(draft),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await widget.controller.move(target);
    if (!mounted) return;
    final error = widget.controller.value.error;
    if (error is PathConflictException) {
      messenger.showSnackBar(
        SnackBar(content: Text('A note already exists at "$target".')),
      );
    } else if (error is LockedException) {
      // Surfaced by the existing "<holder> is editing this note" banner
      // (state.lock is now set to the holder) — no separate snackbar, same
      // as a 423 on save.
    } else if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not move note: ${_describe(error)}')),
      );
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        title: const Text('Delete this note?'),
        content: const Text("This can't be undone."),
        actions: [
          adaptiveDialogAction(
            ctx,
            key: const Key('note.delete.cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          adaptiveDialogAction(
            ctx,
            key: const Key('note.delete.confirm'),
            primary: true,
            destructive: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Resolve the messenger before the screen is popped: the root messenger
    // outlives this route, so the confirmation still shows on the list.
    final messenger = ScaffoldMessenger.of(context);
    await widget.controller.delete();
    if (!mounted) return;
    if (widget.controller.value.mode != NoteMode.deleted) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't delete the note")),
      );
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Note deleted')));
    widget.onClose?.call();
  }

  Widget _buildBody(BuildContext context, NoteState state) {
    final note = state.note;
    if (note == null) {
      final error = state.error;
      if (error != null) {
        return Center(
          child: Text(
            'Could not load the note: ${_describe(error)}',
            key: const Key('note.loadError'),
          ),
        );
      }
      if (state.mode == NoteMode.loading) {
        return const Center(child: CircularProgressIndicator.adaptive());
      }
      return const Center(child: Text('Note unavailable'));
    }

    final banners = <Widget>[];
    if (state.lockedByOtherBanner != null) {
      banners.add(
        StatusStrip(
          key: const Key('note.banner.lockedByOther'),
          message: state.lockedByOtherBanner!,
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
        ),
      );
    } else if (state.mode == NoteMode.viewing &&
        state.lock != null &&
        state.lock!.holder.isNotEmpty) {
      banners.add(
        StatusStrip(
          key: const Key('note.banner.lock'),
          message: '${state.lock!.holder} is editing this note.',
          tone: StatusTone.info,
          icon: Icons.edit_outlined,
        ),
      );
    } else if ((state.mode == NoteMode.editing ||
            state.mode == NoteMode.saving) &&
        state.lock != null) {
      banners.add(_EditingStatus(state: state));
    }

    if (state.mode == NoteMode.conflict) {
      return _ConflictView(
        controller: widget.controller,
        state: state,
        onKeepMine: _keepMine,
        title: _title,
        content: _content,
      );
    }

    final editing =
        state.mode == NoteMode.editing || state.mode == NoteMode.saving;
    return Column(
      children: [
        ...banners,
        if (state.properties.isNotEmpty || state.coveringDefinitions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: PaneSizes.readingColumn,
                ),
                child: NotePropertyPanel(
                  properties: state.properties,
                  coveringDefinitions: state.coveringDefinitions,
                  api: widget.controller.api,
                  onCommit: _onPropertyCommit,
                ),
              ),
            ),
          ),
        Expanded(
          child: editing
              ? _Editor(
                  title: _title,
                  autofocusTitle: widget.startEditing,
                  content: _content,
                  onTitle: widget.controller.setEditTitle,
                  onContent: _onContentChanged,
                  saving: state.mode == NoteMode.saving,
                  linkAutocomplete: _linkAutocomplete,
                  onSelectLink: _insertLink,
                  previewOverride: _previewOverride,
                  onPreviewShown: _setPreviewShown,
                )
              : _ReadingView(
                  note: note,
                  backlinks: state.backlinks,
                  backlinksLoading: state.backlinksLoading,
                  onOpenNote: widget.onOpenNote,
                  onTagTap: widget.onTagTap,
                  onEdit: state.mode == NoteMode.viewing ? _edit : null,
                  onRefresh: _refresh,
                ),
        ),
      ],
    );
  }
}

/// First letter of [name], upper-cased, for an avatar. `?` for a blank name.
String _initial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
}

/// The read-only note as one document: metadata line, rendered body, tag
/// chips, and the backlinks section, all in a single scroll and all on the
/// same reading-width column so nothing sits full-bleed next to a centered
/// body.
class _ReadingView extends StatelessWidget {
  const _ReadingView({
    required this.note,
    required this.backlinks,
    required this.backlinksLoading,
    this.onOpenNote,
    this.onTagTap,
    this.onEdit,
    required this.onRefresh,
  });

  final Note note;
  final List<BacklinkHit> backlinks;
  final bool backlinksLoading;
  final ValueChanged<String>? onOpenNote;
  final ValueChanged<String>? onTagTap;

  /// Double-tapping the body starts editing. `null` while the screen is
  /// busy (acquiring the lock, moving, deleting).
  final VoidCallback? onEdit;

  /// Pulling the document down re-fetches it.
  final RefreshCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    // Take focus when nothing else has it, so the screen's keyboard
    // shortcuts (Cmd/Ctrl+E, Escape) work as soon as a note opens rather
    // than only after a click into the body.
    return Focus(
      autofocus: true,
      // The platform's own pull-to-refresh spinner, as on the notes list.
      child: RefreshIndicator.adaptive(
        key: const Key('note.refresh'),
        onRefresh: onRefresh,
        child: SingleChildScrollView(
          key: const Key('note.scroll'),
          // Always scrollable so a note shorter than the pane can still be
          // pulled to refresh.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: PaneSizes.readingColumn,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MetadataLine(note: note),
                  const SizedBox(height: 12),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: onEdit,
                    child: SelectionArea(
                      child: MarkdownBody(
                        key: const Key('note.body'),
                        data: note.content,
                        styleSheet: AppTheme.markdown(context),
                        // Never fetch images: a note can come from any actor,
                        // and loading a remote URL would leak the reader's IP
                        // to whoever wrote it.
                        imageBuilder: (uri, title, alt) =>
                            Text(alt ?? uri.toString()),
                      ),
                    ),
                  ),
                  if (note.tags.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _TagChips(tags: note.tags, onTap: onTagTap),
                  ],
                  const SizedBox(height: 24),
                  _BacklinksPanel(
                    backlinks: backlinks,
                    loading: backlinksLoading,
                    onOpen: onOpenNote,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Folder path, relative update time, and version — visible at a glance
/// instead of requiring a menu (path was previously only reachable via
/// "Move to folder…"; time and version weren't shown anywhere).
class _MetadataLine extends StatelessWidget {
  const _MetadataLine({required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final parts = [
      if (note.path.isNotEmpty) note.path,
      formatRelativeNoteTime(note.updatedAt),
      'v${note.version}',
    ];
    return Text(
      parts.join(' · '),
      key: const Key('note.metadata'),
      style: style,
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.title,
    required this.autofocusTitle,
    required this.content,
    required this.onTitle,
    required this.onContent,
    required this.saving,
    required this.linkAutocomplete,
    required this.onSelectLink,
    required this.previewOverride,
    required this.onPreviewShown,
  });

  final TextEditingController title;
  final bool autofocusTitle;
  final TextEditingController content;
  final ValueChanged<String> onTitle;
  final ValueChanged<String> onContent;
  final bool saving;
  final LinkAutocompleteController linkAutocomplete;
  final ValueChanged<String> onSelectLink;

  /// See `_NoteScreenState._previewOverride`.
  final bool? previewOverride;
  final ValueChanged<bool> onPreviewShown;

  /// Applies [transform] to [content]'s current value and reports the
  /// result the same way typing does, so undo/dirty-tracking/autocomplete
  /// all see it as an ordinary content change.
  void _applyFormat(
    TextEditingValue Function(TextEditingValue value) transform,
  ) {
    final result = transform(content.value);
    content.value = result;
    onContent(result.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            Breakpoints.fromConstraints(constraints) >= WindowSizeClass.medium;
        final showPreview = previewOverride ?? wide;
        final sideBySide = showPreview && wide;

        final contentField = Column(
          children: [
            Expanded(
              child: TextField(
                key: const Key('note.editor.content'),
                controller: content,
                onChanged: onContent,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Start writing…',
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                enabled: !saving,
              ),
            ),
            _LinkSuggestions(
              linkAutocomplete: linkAutocomplete,
              onSelect: onSelectLink,
            ),
          ],
        );

        final Widget workspace;
        if (!showPreview) {
          workspace = contentField;
        } else {
          final preview = ListenableBuilder(
            listenable: content,
            builder: (context, _) => Markdown(
              key: const Key('note.editor.preview'),
              data: content.text,
              padding: const EdgeInsets.symmetric(vertical: 12),
              styleSheet: AppTheme.markdown(context),
              imageBuilder: (uri, title, alt) => Text(alt ?? uri.toString()),
            ),
          );
          workspace = sideBySide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: contentField),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: VerticalDivider(),
                    ),
                    Expanded(child: preview),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: contentField),
                    const Divider(),
                    Expanded(child: preview),
                  ],
                );
        }

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: sideBySide
                  ? PaneSizes.editorSplit
                  : PaneSizes.readingColumn,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('note.editor.title'),
                    controller: title,
                    autofocus: autofocusTitle,
                    onChanged: onTitle,
                    style: theme.textTheme.headlineSmall,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Title',
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    enabled: !saving,
                  ),
                  _FormattingToolbar(
                    enabled: !saving,
                    onBold: () => _applyFormat((v) => wrapSelection(v, '**')),
                    onItalic: () => _applyFormat((v) => wrapSelection(v, '*')),
                    onHeading: () =>
                        _applyFormat((v) => toggleLinePrefix(v, '# ')),
                    onList: () =>
                        _applyFormat((v) => toggleLinePrefix(v, '- ')),
                    onLink: () => _applyFormat(insertMarkdownLink),
                    previewShown: showPreview,
                    onTogglePreview: () => onPreviewShown(!showPreview),
                  ),
                  const Divider(),
                  Expanded(child: workspace),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Row of formatting actions above the content field: bold/italic wrap
/// the selection, heading/list toggle a marker on the current line, link
/// inserts a `[title](url)` template. All operate on the same
/// [TextEditingController] typing does, via [markdown_toolbar.dart]'s
/// pure `TextEditingValue` transforms. Ends with the live-preview toggle.
/// Scrolls sideways rather than overflowing on a narrow window.
class _FormattingToolbar extends StatelessWidget {
  const _FormattingToolbar({
    required this.enabled,
    required this.onBold,
    required this.onItalic,
    required this.onHeading,
    required this.onList,
    required this.onLink,
    required this.previewShown,
    required this.onTogglePreview,
  });

  final bool enabled;
  final VoidCallback onBold;
  final VoidCallback onItalic;
  final VoidCallback onHeading;
  final VoidCallback onList;
  final VoidCallback onLink;
  final bool previewShown;
  final VoidCallback onTogglePreview;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const Key('note.toolbar.bold'),
            tooltip: 'Bold',
            icon: const Icon(Icons.format_bold),
            onPressed: enabled ? onBold : null,
          ),
          IconButton(
            key: const Key('note.toolbar.italic'),
            tooltip: 'Italic',
            icon: const Icon(Icons.format_italic),
            onPressed: enabled ? onItalic : null,
          ),
          IconButton(
            key: const Key('note.toolbar.heading'),
            tooltip: 'Heading',
            icon: const Icon(Icons.title),
            onPressed: enabled ? onHeading : null,
          ),
          IconButton(
            key: const Key('note.toolbar.list'),
            tooltip: 'List',
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: enabled ? onList : null,
          ),
          IconButton(
            key: const Key('note.toolbar.link'),
            tooltip: 'Link',
            icon: const Icon(Icons.link),
            onPressed: enabled ? onLink : null,
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('note.toolbar.preview'),
            tooltip: previewShown ? 'Hide preview' : 'Show preview',
            isSelected: previewShown,
            icon: const Icon(Icons.visibility),
            selectedIcon: const Icon(Icons.visibility_off),
            onPressed: onTogglePreview,
          ),
        ],
      ),
    );
  }
}

/// Dropdown-like list of matching note titles shown while the cursor sits
/// inside an open `[[...` trigger. Renders nothing when closed or empty,
/// so it costs no layout space the rest of the time.
class _LinkSuggestions extends StatelessWidget {
  const _LinkSuggestions({
    required this.linkAutocomplete,
    required this.onSelect,
  });

  final LinkAutocompleteController linkAutocomplete;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LinkAutocompleteState>(
      valueListenable: linkAutocomplete,
      builder: (context, state, _) {
        if (!state.isOpen || state.suggestions.isEmpty) {
          return const SizedBox.shrink();
        }
        return Container(
          key: const Key('note.editor.linkSuggestions'),
          constraints: const BoxConstraints(maxHeight: 160),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final title in state.suggestions)
                ListTile(
                  key: Key('note.editor.linkSuggestion.$title'),
                  dense: true,
                  title: Text(title),
                  onTap: () => onSelect(title),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Row of chips for the note's computed tags (per `notes-storage`). Tapping
/// a chip (when [onTap] is supplied) is how the notes list gets filtered by
/// tag — see the `Tags are visible and filterable in the UI` requirement.
class _TagChips extends StatelessWidget {
  const _TagChips({required this.tags, this.onTap});

  final List<String> tags;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('note.tags'),
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final tag in tags)
          ActionChip(
            key: Key('note.tags.chip.$tag'),
            label: Text(tag),
            onPressed: onTap == null ? null : () => onTap!(tag),
          ),
      ],
    );
  }
}

/// Backlinks section: notes that link to the one currently open, from
/// `GET /notes/{id}/backlinks`. Shows an empty-state message (not an error)
/// when there are none, since a fetch failure and "genuinely no backlinks"
/// look the same to [NoteController]. When empty, this collapses to a
/// small pill rather than a headed section — there's nothing to show, so
/// it shouldn't claim space as if there were. Part of the reading scroll,
/// not a pinned footer.
class _BacklinksPanel extends StatelessWidget {
  const _BacklinksPanel({
    required this.backlinks,
    required this.loading,
    this.onOpen,
  });

  final List<BacklinkHit> backlinks;
  final bool loading;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    if (backlinks.isEmpty) {
      return Align(
        key: const Key('note.backlinks'),
        alignment: Alignment.centerLeft,
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              )
            : const Chip(
                key: Key('note.backlinks.empty'),
                visualDensity: VisualDensity.compact,
                label: Text('No notes link to this one yet.'),
              ),
      );
    }
    final theme = Theme.of(context);
    return Column(
      key: const Key('note.backlinks'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 12),
        Text(
          'Backlinks',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        for (final hit in backlinks)
          ListTile(
            key: Key('note.backlinks.item.${hit.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(hit.title.isEmpty ? '(untitled)' : hit.title),
            subtitle: Text(
              hit.snippet,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: onOpen == null ? null : () => onOpen!(hit.id),
          ),
      ],
    );
  }
}

/// One span per line of [text]; lines [other] does not contain get [mark].
List<TextSpan> _lineDiffSpans(String text, String other, TextStyle mark) {
  final lines = text.split('\n');
  final otherLines = other.split('\n').toSet();
  return [
    for (var i = 0; i < lines.length; i++) ...[
      TextSpan(
        text: lines[i],
        style: otherLines.contains(lines[i]) ? null : mark,
      ),
      if (i < lines.length - 1) const TextSpan(text: '\n'),
    ],
  ];
}

/// Highlight for text one side of a conflict has and the other lacks.
TextStyle _mark(ColorScheme scheme, {required bool mine}) => TextStyle(
  backgroundColor: mine ? scheme.primaryContainer : scheme.tertiaryContainer,
  color: mine ? scheme.onPrimaryContainer : scheme.onTertiaryContainer,
);

/// Content buffer that, while a conflict is open, shades the lines the
/// server's copy does not contain — the editable "Yours" pane then carries
/// the same marks as the read-only server pane.
class _DiffTextController extends TextEditingController {
  _DiffTextController(this._serverContent);

  final String? Function() _serverContent;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final server = _serverContent();
    if (server == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final mark = _mark(Theme.of(context).colorScheme, mine: true);
    return TextSpan(style: style, children: _lineDiffSpans(text, server, mark));
  }
}

class _ConflictView extends StatelessWidget {
  const _ConflictView({
    required this.controller,
    required this.state,
    required this.onKeepMine,
    required this.title,
    required this.content,
  });

  final NoteController controller;
  final NoteState state;
  final VoidCallback onKeepMine;
  final TextEditingController title;
  final TextEditingController content;

  @override
  Widget build(BuildContext context) {
    final theirs = state.conflictCurrent;
    final serverTitle = theirs?.title ?? '';
    final titleDiffers = serverTitle != (state.editTitle ?? '');
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium;
    final serverMark = _mark(theme.colorScheme, mine: false);
    final mineMark = _mark(theme.colorScheme, mine: true);

    final server = _DiffPane(
      key: const Key('note.conflict.server'),
      label: 'Server (v${theirs?.version ?? '?'})',
      title: Text(
        serverTitle.isEmpty ? '(untitled)' : serverTitle,
        key: const Key('note.conflict.serverTitle'),
        style: titleStyle?.merge(titleDiffers ? serverMark : null),
      ),
      body: SingleChildScrollView(
        child: SelectableText.rich(
          TextSpan(
            children: _lineDiffSpans(
              theirs?.content ?? '',
              state.editContent ?? '',
              serverMark,
            ),
          ),
          key: const Key('note.conflict.serverContent'),
        ),
      ),
    );

    final yours = _DiffPane(
      key: const Key('note.conflict.yours'),
      label: 'Yours',
      title: TextField(
        key: const Key('note.conflict.title'),
        controller: title,
        onChanged: controller.setEditTitle,
        style: titleStyle?.merge(titleDiffers ? mineMark : null),
        decoration: const InputDecoration(labelText: 'Title', isDense: true),
      ),
      body: TextField(
        key: const Key('note.conflict.content'),
        controller: content,
        onChanged: controller.setEditContent,
        decoration: const InputDecoration.collapsed(hintText: 'Content'),
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
      ),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PaneSizes.editorSplit),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const StatusStrip(
                key: Key('note.banner.conflict'),
                message:
                    'This note changed on the server. Use the server version, or edit yours and save it.',
                tone: StatusTone.warning,
                icon: Icons.sync_problem,
                rounded: true,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Flex(
                    direction:
                        Breakpoints.fromConstraints(constraints) >=
                            WindowSizeClass.medium
                        ? Axis.horizontal
                        : Axis.vertical,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: server),
                      const SizedBox.square(dimension: 12),
                      Expanded(child: yours),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    key: const Key('note.conflict.acceptServer'),
                    onPressed: controller.resolveConflictAcceptServer,
                    child: const Text('Use server version'),
                  ),
                  FilledButton(
                    key: const Key('note.conflict.keepMine'),
                    onPressed: onKeepMine,
                    child: const Text('Save mine'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiffPane extends StatelessWidget {
  const _DiffPane({
    required this.label,
    this.title,
    required this.body,
    super.key,
  });

  final String label;

  /// Per-pane header content (e.g. the conflicting title fields). `null`
  /// when the pane doesn't need one of its own — the editor's split view
  /// has a single title field above both panes instead.
  final Widget? title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            if (title != null) ...[title!, const SizedBox(height: 8)],
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Formats [dt] in the device's local time zone as `HH:MM`, for the
/// "Autosaved HH:MM" editing status. Kept top-level so tests can pin a
/// known instant.
String formatLockExpiry(DateTime dt) => formatClockTime(dt);

/// Who's viewing the note, as a row of overlapping initials in the app
/// bar: up to three avatars, then a "+N" for the rest. The full list is in
/// the tooltip and in the semantics label, since initials alone don't
/// identify anyone.
class _PresenceAvatars extends StatelessWidget {
  const _PresenceAvatars({required this.viewers, super.key});

  final List<String> viewers;

  static const int _maxShown = 3;
  static const double _radius = 12;

  /// Ring of surface color around each avatar so the overlaps read as
  /// separate circles.
  static const double _ring = 2;
  static const double _size = 2 * (_radius + _ring);

  /// Horizontal distance between the left edges of neighbouring avatars.
  static const double _step = _size - 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final names = viewers.join(', ');
    final shown = viewers.take(_maxShown).toList();
    final extra = viewers.length - shown.length;
    final count = shown.length + (extra > 0 ? 1 : 0);

    Widget avatar(String label, {required bool overflow}) => Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: scheme.surface, width: _ring),
      ),
      child: CircleAvatar(
        radius: _radius,
        backgroundColor: overflow
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        foregroundColor: overflow
            ? scheme.onSurfaceVariant
            : scheme.onPrimaryContainer,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: overflow
                ? scheme.onSurfaceVariant
                : scheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    return Semantics(
      container: true,
      label: '${viewers.length == 1 ? 'Viewer' : 'Viewers'}: $names',
      child: Tooltip(
        message: names,
        child: ExcludeSemantics(
          child: SizedBox(
            width: _size + _step * (count - 1),
            height: _size,
            child: Stack(
              children: [
                for (var i = 0; i < shown.length; i++)
                  Positioned(
                    left: i * _step,
                    child: avatar(_initial(shown[i]), overflow: false),
                  ),
                if (extra > 0)
                  Positioned(
                    left: shown.length * _step,
                    child: avatar('+$extra', overflow: true),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Who's editing and whether their latest change is saved, at a glance —
/// replaces the old plain lock-countdown banner now that saving is
/// automatic. The avatar's initial is [NoteState.lock]'s holder, which is
/// always the current actor's own name while editing (the lock is theirs).
class _EditingStatus extends StatelessWidget {
  const _EditingStatus({required this.state});

  final NoteState state;

  @override
  Widget build(BuildContext context) {
    final holder = state.lock!.holder;
    final String text;
    if (state.mode == NoteMode.saving) {
      text = 'Saving…';
    } else if (state.isDirty) {
      text = 'Unsaved changes';
    } else {
      text = 'Autosaved ${formatLockExpiry(state.note!.updatedAt)}';
    }
    return StatusStrip(
      key: const Key('note.editingStatus'),
      message: text,
      tone: StatusTone.info,
      leading: CircleAvatar(
        radius: 12,
        child: Text(
          _initial(holder),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}
