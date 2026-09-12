import 'package:flutter/material.dart';

import '../api/api_exceptions.dart';
import 'note_controller.dart';

/// Single-note view. Renders three modes off [NoteController]:
///
/// - viewing: read-only Markdown source + presence/lock indicators.
/// - editing: title and content text fields, save / cancel actions.
/// - conflict: 409 reconcile UI showing both versions.
///
/// Locking is handled by the controller; this widget just dispatches.
class NoteScreen extends StatefulWidget {
  const NoteScreen({required this.controller, this.onClose, super.key});

  final NoteController controller;
  final VoidCallback? onClose;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _content = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncBuffersFromState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.open();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncBuffersFromState);
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    await widget.controller.enterEditMode();
    _announceOutcome(failed: 'Could not start editing');
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
                  child: Text(
                    '${state.viewers.length} viewer${state.viewers.length == 1 ? '' : 's'}',
                    key: const Key('note.presence'),
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
          ],
        ),
        body: _buildBody(context, state),
      ),
    );
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
    }

    if (state.mode == NoteMode.conflict) {
      return _ConflictView(
        controller: widget.controller,
        state: state,
        onKeepMine: _keepMine,
      );
    }

    return Column(
      children: [
        ...banners,
        Expanded(
          child: state.mode == NoteMode.editing || state.mode == NoteMode.saving
              ? _Editor(
                  title: _title,
                  content: _content,
                  onTitle: widget.controller.setEditTitle,
                  onContent: widget.controller.setEditContent,
                  saving: state.mode == NoteMode.saving,
                )
              : _ReadOnlyView(content: note.content),
        ),
      ],
    );
  }
}

class _ReadOnlyView extends StatelessWidget {
  const _ReadOnlyView({required this.content});
  final String content;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(content, key: const Key('note.body')),
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.title,
    required this.content,
    required this.onTitle,
    required this.onContent,
    required this.saving,
  });

  final TextEditingController title;
  final TextEditingController content;
  final ValueChanged<String> onTitle;
  final ValueChanged<String> onContent;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            key: const Key('note.editor.title'),
            controller: title,
            onChanged: onTitle,
            decoration: const InputDecoration(labelText: 'Title'),
            enabled: !saving,
          ),
          const SizedBox(height: 12),
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
        ],
      ),
    );
  }
}

class _ConflictView extends StatelessWidget {
  const _ConflictView({
    required this.controller,
    required this.state,
    required this.onKeepMine,
  });

  final NoteController controller;
  final NoteState state;
  final VoidCallback onKeepMine;

  @override
  Widget build(BuildContext context) {
    final theirs = state.conflictCurrent;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Banner(
            key: Key('note.banner.conflict'),
            text:
                'This note has been updated on the server. Pick a version to continue.',
            tone: _BannerTone.warning,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _DiffPane(
                    label: 'Server (v${theirs?.version ?? '?'})',
                    body: theirs?.content ?? '',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DiffPane(
                    label: 'Yours',
                    body: state.editContent ?? '',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                key: const Key('note.conflict.acceptServer'),
                onPressed: controller.resolveConflictAcceptServer,
                child: const Text('Use server version'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const Key('note.conflict.keepMine'),
                onPressed: onKeepMine,
                child: const Text('Force overwrite with mine'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiffPane extends StatelessWidget {
  const _DiffPane({required this.label, required this.body});
  final String label;
  final String body;

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            Expanded(child: SingleChildScrollView(child: SelectableText(body))),
          ],
        ),
      ),
    );
  }
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
