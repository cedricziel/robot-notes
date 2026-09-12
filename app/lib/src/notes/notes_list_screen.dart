import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../widgets/error_strip.dart';
import 'notes_list_controller.dart';

/// Notes list view. Backed by [NotesListController]; the controller is
/// injected so widget tests can drive it without a real network.
///
/// - Pull-to-refresh re-issues `GET /notes`.
/// - A failed fetch shows a strip above the list with a retry; items that
///   already loaded stay visible.
/// - Scrolling near the end pages in the next cursor batch.
/// - Live `changed` events flow into the controller and reflect here without
///   manual refresh.
class NotesListScreen extends StatefulWidget {
  const NotesListScreen({
    required this.controller,
    this.onNoteTap,
    this.onCreate,
    this.appBarActions,
    this.sidebar,
    super.key,
  });

  final NotesListController controller;
  final ValueChanged<String>? onNoteTap;
  final VoidCallback? onCreate;

  /// Optional widgets rendered as the AppBar actions (e.g. search + reset
  /// affordances supplied by the host shell). When `null` the AppBar
  /// shows just the title.
  final List<Widget>? appBarActions;

  /// The folder tree navigation panel. When supplied, it renders as a fixed
  /// column beside the list on wide screens (>= 700 logical pixels) and
  /// inside a [Drawer] behind the usual hamburger affordance on narrow
  /// ones. `null` renders no folder navigation at all.
  final Widget? sidebar;

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

  Future<void> _confirmDelete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            key: const Key('notes.delete.cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('notes.delete.confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final deleted = await widget.controller.delete(id);
    if (!mounted || !deleted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Note deleted')));
  }

  /// Below this width the sidebar moves into a [Drawer] instead of sitting
  /// beside the list permanently.
  static const _wideBreakpoint = 700.0;

  @override
  Widget build(BuildContext context) {
    final sidebar = widget.sidebar;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Wide-layout affordances (hover-delete, the toolbar's "New note"
        // action) are keyed off screen width alone; the sidebar's own
        // inline-vs-drawer placement additionally requires one to exist.
        final isWide = constraints.maxWidth >= _wideBreakpoint;
        final showSidebarInline = sidebar != null && isWide;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Notes'),
            actions: [
              if (isWide && widget.onCreate != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextButton.icon(
                    key: const Key('notes.create.toolbar'),
                    onPressed: widget.onCreate,
                    icon: const Icon(Icons.add),
                    label: const Text('New note'),
                  ),
                ),
              ...?widget.appBarActions,
            ],
          ),
          drawer: sidebar == null || showSidebarInline
              ? null
              : Drawer(key: const Key('notes.sidebar.drawer'), child: sidebar),
          floatingActionButton: widget.onCreate == null || isWide
              ? null
              : FloatingActionButton(
                  key: const Key('notes.create'),
                  tooltip: 'New note',
                  onPressed: widget.onCreate,
                  child: const Icon(Icons.add),
                ),
          body: showSidebarInline
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      key: const Key('notes.sidebar.wide'),
                      width: 260,
                      child: sidebar,
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildListBody(context, wide: isWide)),
                  ],
                )
              : _buildListBody(context, wide: isWide),
        );
      },
    );
  }

  Widget _buildListBody(BuildContext context, {required bool wide}) {
    return Column(
      children: [
        Expanded(
          child: ValueListenableBuilder<NotesListState>(
            valueListenable: widget.controller,
            builder: (context, state, _) {
              if (state.isLoadingFirst && state.items.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              final error = state.error;
              final tag = state.selectedTag;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tag != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Chip(
                        key: const Key('notes.filter.tag'),
                        label: Text('Tag: $tag'),
                        deleteIcon: const Icon(
                          Icons.close,
                          key: Key('notes.filter.tag.clear'),
                        ),
                        onDeleted: () => widget.controller.selectTag(null),
                      ),
                    ),
                  if (error != null)
                    ErrorStrip(
                      key: const Key('notes.error'),
                      message: describeError(
                        error,
                        fallback: 'Could not load notes.',
                      ),
                      onRetry: widget.controller.refresh,
                    ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: widget.controller.refresh,
                      child: ListView.separated(
                        key: const Key('notes.list'),
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount:
                            state.items.length + (state.isLoadingMore ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(height: 1),
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
                            wide: wide,
                            onTap: widget.onNoteTap == null
                                ? null
                                : () => widget.onNoteTap!(note.id),
                            onDelete: () => _confirmDelete(note.id),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NoteTile extends StatefulWidget {
  const _NoteTile({
    required this.note,
    required this.wide,
    this.onTap,
    required this.onDelete,
  });

  final NoteMeta note;

  /// Whether the row is laid out wide enough for hover-to-reveal delete —
  /// on narrow/touch layouts, long-press/right-click (via [MenuAnchor])
  /// remains the only delete affordance.
  final bool wide;
  final VoidCallback? onTap;
  final VoidCallback onDelete;

  @override
  State<_NoteTile> createState() => _NoteTileState();
}

class _NoteTileState extends State<_NoteTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final theme = Theme.of(context);
    final path = note.path;
    final tile = ListTile(
      key: Key('notes.tile.${note.id}'),
      title: Row(
        children: [
          Expanded(
            child: Text(
              note.title.isEmpty ? '(untitled)' : note.title,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (path.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                path,
                key: Key('notes.tile.${note.id}.path'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (note.excerpt.isNotEmpty)
            Text(note.excerpt, overflow: TextOverflow.ellipsis),
          Row(
            children: [
              if (note.tags.isNotEmpty)
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final tag in note.tags)
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                )
              else
                const Spacer(),
              Text(
                formatRelativeNoteTime(note.updatedAt),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
      onTap: widget.onTap,
      trailing: widget.wide && _hovering
          ? IconButton(
              key: Key('notes.tile.${note.id}.hoverDelete'),
              tooltip: 'Delete note',
              icon: const Icon(Icons.delete_outline),
              onPressed: widget.onDelete,
            )
          : null,
    );
    final menu = MenuAnchor(
      key: Key('notes.tile.${note.id}.menu'),
      menuChildren: [
        MenuItemButton(
          key: Key('notes.tile.${note.id}.delete'),
          onPressed: widget.onDelete,
          child: const Text('Delete note'),
        ),
      ],
      builder: (context, controller, child) {
        return GestureDetector(
          onLongPress: controller.open,
          onSecondaryTap: controller.open,
          child: child,
        );
      },
      child: tile,
    );
    if (!widget.wide) return menu;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: menu,
    );
  }
}

/// Formats [dt] in the device's local time zone as `YYYY-MM-DD HH:MM`.
/// Kept top-level so tests can pin a known instant.
String formatNoteTimestamp(DateTime dt) {
  final t = dt.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Formats [dt] relative to [now] (defaulting to the current instant) as
/// "just now" / "N minute(s) ago" / "N hour(s) ago" / "N day(s) ago", or
/// falls back to [formatNoteTimestamp] beyond a week — an absolute date is
/// more useful than "N days ago" once the gap gets that wide.
String formatRelativeNoteTime(DateTime dt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(dt);
  if (diff.inDays >= 7) return formatNoteTimestamp(dt);
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
