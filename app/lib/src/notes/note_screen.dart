import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import 'link_autocomplete.dart';
import 'note_controller.dart';
import 'save_shortcut.dart';

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

  String? _serverContent() {
    final s = widget.controller.value;
    if (s.mode != NoteMode.conflict) return null;
    return s.conflictCurrent?.content ?? '';
  }

  late final VoidCallback _uninstallWebSaveShortcut;

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
  void dispose() {
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
  }

  static void _syncField(TextEditingController field, String? buffer) {
    final next = buffer ?? '';
    if (field.text != next) field.text = next;
  }

  Future<bool> _confirmDiscard() async {
    if (!widget.controller.value.isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this note have not been saved.'),
        actions: [
          TextButton(
            key: const Key('note.discard.keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton.tonal(
            key: const Key('note.discard.confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _close() async {
    if (!await _confirmDiscard()) return;
    await widget.controller.exitEditing();
    if (mounted) widget.onClose?.call();
  }

  Future<void> _onPopInvoked(bool didPop, Object? result) async {
    if (!didPop) await _close();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final note = state.note;
    return PopScope(
      canPop: !state.isDirty,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('note.close'),
            tooltip: 'Close',
            icon: const Icon(Icons.close),
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
                  child: Tooltip(
                    message: state.viewers.join(', '),
                    child: Text(
                      state.viewers.length <= 3
                          ? state.viewers.join(', ')
                          : '${state.viewers.length} viewers',
                      key: const Key('note.presence'),
                    ),
                  ),
                ),
              ),
            if (state.mode == NoteMode.viewing && note != null)
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
            if (state.mode == NoteMode.viewing && note != null)
              PopupMenuButton<void>(
                key: const Key('note.menu'),
                itemBuilder: (_) => [
                  PopupMenuItem<void>(
                    key: const Key('note.move'),
                    onTap: _confirmMove,
                    child: const Text('Move to folder…'),
                  ),
                  PopupMenuItem<void>(
                    key: const Key('note.delete'),
                    onTap: _confirmDelete,
                    child: const Text('Delete note'),
                  ),
                ],
              ),
          ],
        ),
        body: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            if (state.mode == NoteMode.editing) ...{
              const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
              const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                  _save,
            },
            const SingleActivator(LogicalKeyboardKey.escape): _close,
          },
          child: _buildBody(context, state),
        ),
      ),
    );
  }

  /// Free-text folder path entry (see `design.md`'s note on this vs. a full
  /// tree picker). Prefills with the note's current folder so the user
  /// edits from there rather than retyping it.
  Future<void> _confirmMove() async {
    final note = widget.controller.value.note;
    if (note == null) return;
    // A `TextFormField` (rather than a `TextField` + an explicit
    // `TextEditingController`) owns and disposes its own internal
    // controller, so there's nothing to clean up once the dialog closes.
    var draft = note.path;
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to folder'),
        content: TextFormField(
          key: const Key('note.move.input'),
          initialValue: note.path,
          autofocus: true,
          onChanged: (v) => draft = v,
          decoration: const InputDecoration(
            labelText: 'Folder path',
            hintText: 'e.g. Projects/Alpha (blank for the vault root)',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('note.move.cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('note.move.confirm'),
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
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            key: const Key('note.delete.cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('note.delete.confirm'),
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
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(child: Text('Note unavailable'));
    }

    final banners = <Widget>[];
    if (state.lockedByOtherBanner != null) {
      banners.add(
        _Banner(
          key: const Key('note.banner.lockedByOther'),
          text: state.lockedByOtherBanner!,
          tone: _BannerTone.warning,
        ),
      );
    } else if (state.mode == NoteMode.viewing &&
        state.lock != null &&
        state.lock!.holder.isNotEmpty) {
      banners.add(
        _Banner(
          key: const Key('note.banner.lock'),
          text: '${state.lock!.holder} is editing this note.',
          tone: _BannerTone.info,
        ),
      );
    } else if (state.mode == NoteMode.editing && state.lock != null) {
      banners.add(
        _Banner(
          key: const Key('note.banner.ownLock'),
          text:
              'You are editing (lock until '
              '${formatLockExpiry(state.lock!.expiresAt)})',
          tone: _BannerTone.info,
        ),
      );
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
                )
              : Column(
                  children: [
                    _MetadataLine(note: note),
                    Expanded(child: _ReadOnlyView(content: note.content)),
                    if (note.tags.isNotEmpty)
                      _TagChips(tags: note.tags, onTap: widget.onTagTap),
                    _BacklinksPanel(
                      backlinks: state.backlinks,
                      loading: state.backlinksLoading,
                      onOpen: widget.onOpenNote,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A wide window turns a comfortable reading line into an uncomfortably
/// long one; cap it like a document, not an app panel that fills whatever
/// space it's given.
const double _maxReadingWidth = 760;

class _ReadOnlyView extends StatelessWidget {
  const _ReadOnlyView({required this.content});
  final String content;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxReadingWidth),
        child: SelectionArea(
          child: Markdown(
            key: const Key('note.body'),
            data: content,
            padding: const EdgeInsets.all(16),
            // Never fetch images: a note can come from any actor, and
            // loading a remote URL would leak the reader's IP to whoever
            // wrote it.
            imageBuilder: (uri, title, alt) => Text(alt ?? uri.toString()),
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
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor);
    final parts = [
      if (note.path.isNotEmpty) note.path,
      _formatRelativeTime(note.updatedAt),
      'v${note.version}',
    ];
    return Padding(
      key: const Key('note.metadata'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(parts.join(' · '), style: style),
    );
  }
}

/// Formats [dt] relative to now as "just now" / "N minute(s) ago" / "N
/// hour(s) ago" / "N day(s) ago", falling back to an absolute date beyond
/// a week. A near-duplicate of the notes-list row's relative-time helper
/// (`notes_list_screen.dart`'s `formatRelativeNoteTime`, in an unmerged
/// sibling change at time of writing) — worth consolidating into a
/// shared util once both land, not worth blocking either on the other.
String _formatRelativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inDays >= 7) {
    final t = dt.toLocal();
    return '${t.year}-${_twoDigits(t.month)}-${_twoDigits(t.day)}';
  }
  if (diff.inDays >= 1) {
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
  if (diff.inHours >= 1) {
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  }
  if (diff.inMinutes >= 1) {
    return '${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago';
  }
  return 'just now';
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

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
  });

  final TextEditingController title;
  final bool autofocusTitle;
  final TextEditingController content;
  final ValueChanged<String> onTitle;
  final ValueChanged<String> onContent;
  final bool saving;
  final LinkAutocompleteController linkAutocomplete;
  final ValueChanged<String> onSelectLink;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            key: const Key('note.editor.title'),
            controller: title,
            autofocus: autofocusTitle,
            onChanged: onTitle,
            decoration: const InputDecoration(labelText: 'Title'),
            enabled: !saving,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('note.editor.content'),
                    controller: content,
                    onChanged: onContent,
                    decoration: const InputDecoration(
                      labelText: 'Content',
                      alignLabelWithHint: true,
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
            ),
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
    return Padding(
      key: const Key('note.tags'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(
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
      ),
    );
  }
}

/// Backlinks panel: notes that link to the one currently open, from
/// `GET /notes/{id}/backlinks`. Shows an empty-state message (not an error)
/// when there are none, since a fetch failure and "genuinely no backlinks"
/// look the same to [NoteController]. When empty, this collapses to a
/// small pill rather than the full bordered panel with its own heading —
/// there's nothing to show, so it shouldn't claim footer space as if
/// there were.
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
      return Padding(
        key: const Key('note.backlinks'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Chip(
                  key: Key('note.backlinks.empty'),
                  visualDensity: VisualDensity.compact,
                  label: Text('No notes link to this one yet.'),
                ),
        ),
      );
    }
    return Container(
      key: const Key('note.backlinks'),
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Backlinks',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final hit in backlinks)
                  ListTile(
                    key: Key('note.backlinks.item.${hit.id}'),
                    dense: true,
                    title: Text(hit.title.isEmpty ? '(untitled)' : hit.title),
                    subtitle: Text(
                      hit.snippet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: onOpen == null ? null : () => onOpen!(hit.id),
                  ),
              ],
            ),
          ),
        ],
      ),
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

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Banner(
            key: Key('note.banner.conflict'),
            text:
                'This note changed on the server. Use the server version, or edit yours and save it.',
            tone: _BannerTone.warning,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Flex(
                direction: constraints.maxWidth < 600
                    ? Axis.vertical
                    : Axis.horizontal,
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
    );
  }
}

class _DiffPane extends StatelessWidget {
  const _DiffPane({
    required this.label,
    required this.title,
    required this.body,
    super.key,
  });

  final String label;
  final Widget title;
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
            title,
            const SizedBox(height: 8),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Formats [dt] in the device's local time zone as `HH:MM`, for the "you
/// hold the lock until" banner. Kept top-level so tests can pin a known
/// instant.
String formatLockExpiry(DateTime dt) {
  final t = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

enum _BannerTone { info, warning }

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.tone, super.key});
  final String text;
  final _BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = tone == _BannerTone.warning
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final fg = tone == _BannerTone.warning
        ? scheme.onErrorContainer
        : scheme.onSurface;
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Text(text, style: TextStyle(color: fg)),
    );
  }
}
