import 'package:flutter/material.dart';

import 'note_controller.dart';

/// Single-note view. Renders three modes off [NoteController]:
///
/// - viewing: read-only Markdown source + presence/lock indicators.
/// - editing: title and content text fields, save / cancel actions.
/// - conflict: 409 reconcile UI showing both versions.
///
/// Locking is handled by the controller; this widget just dispatches.
class NoteScreen extends StatefulWidget {
  const NoteScreen({
    required this.controller,
    this.onClose,
    super.key,
  });

  final NoteController controller;
  final VoidCallback? onClose;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _content = TextEditingController();
  String? _lastSyncedTitle;
  String? _lastSyncedContent;

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

  /// Sync the TextField contents whenever the controller's edit buffers
  /// change underneath us — e.g. after a save sets them to the server's
  /// latest, or after accepting the server side of a conflict.
  void _syncBuffersFromState() {
    final s = widget.controller.value;
    if (s.editTitle != _lastSyncedTitle) {
      _lastSyncedTitle = s.editTitle;
      _title.text = s.editTitle ?? '';
    }
    if (s.editContent != _lastSyncedContent) {
      _lastSyncedContent = s.editContent;
      _content.text = s.editContent ?? '';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final note = state.note;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            if (state.mode == NoteMode.editing ||
                state.mode == NoteMode.conflict) {
              await widget.controller.exitEditing();
            }
            widget.onClose?.call();
          },
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
              icon: const Icon(Icons.edit),
              onPressed: widget.controller.enterEditMode,
            ),
          if (state.mode == NoteMode.editing)
            TextButton(
              key: const Key('note.save'),
              onPressed: widget.controller.save,
              child: const Text('Save'),
            ),
        ],
      ),
      body: _buildBody(context, state),
    );
  }

  Widget _buildBody(BuildContext context, NoteState state) {
    if (state.mode == NoteMode.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final note = state.note;
    if (note == null) {
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
      child: SelectableText(
        content,
        key: const Key('note.body'),
      ),
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
  const _ConflictView({required this.controller, required this.state});

  final NoteController controller;
  final NoteState state;

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
                onPressed: controller.resolveConflictKeepMine,
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
            Expanded(
              child: SingleChildScrollView(child: SelectableText(body)),
            ),
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
