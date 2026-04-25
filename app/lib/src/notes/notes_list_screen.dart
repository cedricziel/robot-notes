import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'notes_list_controller.dart';

/// Notes list view. Backed by [NotesListController]; the controller is
/// injected so widget tests can drive it without a real network.
///
/// - Pull-to-refresh re-issues `GET /notes`.
/// - Scrolling near the end pages in the next cursor batch.
/// - Live `changed` events flow into the controller and reflect here without
///   manual refresh.
class NotesListScreen extends StatefulWidget {
  const NotesListScreen({
    required this.controller,
    this.onNoteTap,
    this.onCreate,
    this.appBarActions,
    super.key,
  });

  final NotesListController controller;
  final ValueChanged<String>? onNoteTap;
  final VoidCallback? onCreate;

  /// Optional widgets rendered as the AppBar actions (e.g. search + reset
  /// affordances supplied by the host shell). When `null` the AppBar
  /// shows just the title.
  final List<Widget>? appBarActions;

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_onScroll);
    // Kick off the initial fetch after the first frame so any tests
    // observing the loading state have a chance to set up listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.refresh();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      widget.controller.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        actions: widget.appBarActions,
      ),
      floatingActionButton: widget.onCreate == null
          ? null
          : FloatingActionButton(
              key: const Key('notes.create'),
              onPressed: widget.onCreate,
              child: const Icon(Icons.add),
            ),
      body: ValueListenableBuilder<NotesListState>(
        valueListenable: widget.controller,
        builder: (context, state, _) {
          if (state.isLoadingFirst && state.items.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: widget.controller.refresh,
            child: ListView.separated(
              key: const Key('notes.list'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: state.items.length + (state.isLoadingMore ? 1 : 0),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index >= state.items.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final note = state.items[index];
                return _NoteTile(
                  note: note,
                  onTap: widget.onNoteTap == null
                      ? null
                      : () => widget.onNoteTap!(note.id),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, this.onTap});

  final NoteMeta note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('notes.tile.${note.id}'),
      title: Text(note.title.isEmpty ? '(untitled)' : note.title),
      subtitle: Text('v${note.version} · ${_formatTimestamp(note.updatedAt)}'),
      onTap: onTap,
    );
  }

  String _formatTimestamp(DateTime dt) {
    final iso = dt.toUtc().toIso8601String();
    // YYYY-MM-DD HH:MM — readable enough for v1, no localization needed yet.
    return '${iso.substring(0, 10)} ${iso.substring(11, 16)}Z';
  }
}
