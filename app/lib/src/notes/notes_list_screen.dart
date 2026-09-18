import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../format/note_time.dart';
import '../layout/breakpoints.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_strip.dart';
import '../widgets/resizable_panel.dart';
import 'notes_list_controller.dart';

export '../format/note_time.dart'
    show formatNoteTimestamp, formatRelativeNoteTime;

/// Which chrome [NotesListScreen] renders.
///
/// - [narrow]: phone chrome — bottom nav, FAB menu, folder drawer.
/// - [wide]: toolbar actions in the app bar and an inline, resizable
///   folder sidebar.
///
/// Normally derived from the screen's own constraints (wide at
/// [WindowSizeClass.medium] and up); the three-pane shell pins it so the
/// list pane keeps wide chrome even though it is narrower than a phone.
enum NotesListLayout { narrow, wide }

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
    this.onCreateNote,
    this.onCreateFolder,
    this.onUploadFile,
    this.onSearch,
    this.onAccount,
    this.sidebar,
    this.layout,
    this.selectedNoteId,
    super.key,
  });

  final NotesListController controller;
  final ValueChanged<String>? onNoteTap;

  /// Invoked when the user chooses "New note" — from the wide-layout
  /// toolbar button, the narrow-layout FAB menu, or the empty state's
  /// call to action. `null` hides all of them.
  final VoidCallback? onCreateNote;

  /// Invoked when the user chooses "New folder" from the narrow-layout
  /// FAB menu. That menu item is omitted when this is `null`. On wide
  /// layouts, folder creation is reached via the inline sidebar's own
  /// "New folder" action instead — the FAB doesn't exist there at all.
  final VoidCallback? onCreateFolder;

  /// Invoked when the user chooses "Upload file" — from the narrow-layout
  /// FAB menu or the wide-layout toolbar. Both are omitted when `null`.
  final VoidCallback? onUploadFile;

  /// Invoked by the narrow-layout bottom nav's "Search" destination and
  /// the wide-layout toolbar's search action. Both are omitted when
  /// `null`.
  final VoidCallback? onSearch;

  /// Invoked by the narrow-layout bottom nav's "Account" destination and
  /// the wide-layout toolbar's account action. Both are omitted when
  /// `null`.
  final VoidCallback? onAccount;

  /// The folder tree navigation panel. When supplied, it renders as a
  /// resizable column beside the list on wide layouts and inside a
  /// [Drawer] on narrow ones, opened via the bottom nav's "Folders"
  /// destination (there is no AppBar hamburger). `null` renders no folder
  /// navigation and no "Folders" destination.
  final Widget? sidebar;

  /// Forces the chrome regardless of the available width. `null` derives
  /// it from this widget's own constraints via [Breakpoints].
  final NotesListLayout? layout;

  /// The note currently open beside the list (three-pane shell); its row
  /// renders selected. `null` highlights nothing.
  final String? selectedNoteId;

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> {
  late final ScrollController _scroll;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  double _sidebarWidth = PaneSizes.sidebarDefault;

  /// False until the post-frame initial [NotesListController.refresh] has
  /// been issued, so the very first frame shows the spinner rather than
  /// flashing "No notes yet" over a vault that simply hasn't loaded.
  bool _fetchStarted = false;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_onScroll);
    // Kick off the initial fetch after the first frame so any tests
    // observing the loading state have a chance to set up listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _fetchStarted = true);
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

  /// Display name of a folder scope: its last path segment, or "Root" for
  /// the vault root (`''`).
  static String _folderLabel(String path) {
    if (path.isEmpty) return 'Root';
    final segments = path.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? 'Root' : segments.last;
  }

  static String _titleFor(String? selectedPath) =>
      selectedPath == null ? 'Notes' : _folderLabel(selectedPath);

  @override
  Widget build(BuildContext context) {
    final sidebar = widget.sidebar;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Wide-layout affordances (hover-delete, the toolbar actions) are
        // keyed off the layout alone; the sidebar's own inline-vs-drawer
        // placement additionally requires one to exist.
        final isWide = switch (widget.layout) {
          NotesListLayout.wide => true,
          NotesListLayout.narrow => false,
          null =>
            Breakpoints.fromConstraints(constraints) >= WindowSizeClass.medium,
        };
        final showSidebarInline = sidebar != null && isWide;
        return ValueListenableBuilder<NotesListState>(
          valueListenable: widget.controller,
          builder: (context, state, _) {
            return Scaffold(
              key: _scaffoldKey,
              appBar: AppBar(
                title: Text(
                  _titleFor(state.selectedPath),
                  key: const Key('notes.title'),
                ),
                // The narrow bottom nav's "Folders" destination opens the
                // drawer, so the default hamburger would be a redundant
                // second way to do the same thing — suppress it there.
                // Wide layouts never have a drawer, so this has no effect
                // on them.
                automaticallyImplyLeading: isWide,
                actions: isWide ? _toolbarActions() : const [],
              ),
              drawer: sidebar == null || showSidebarInline
                  ? null
                  : Drawer(
                      key: const Key('notes.sidebar.drawer'),
                      child: sidebar,
                    ),
              floatingActionButton: widget.onCreateNote == null || isWide
                  ? null
                  : _buildCreateMenu(),
              bottomNavigationBar: isWide
                  ? null
                  : _BottomNav(
                      hasFolders: sidebar != null,
                      onSearch: widget.onSearch,
                      onFolders: () => _scaffoldKey.currentState?.openDrawer(),
                      onAccount: widget.onAccount,
                    ),
              body: showSidebarInline
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ResizablePanel(
                          width: _sidebarWidth,
                          minWidth: PaneSizes.sidebarMin,
                          maxWidth: PaneSizes.sidebarMax,
                          onWidthChanged: (w) =>
                              setState(() => _sidebarWidth = w),
                          child: SizedBox.expand(
                            key: const Key('notes.sidebar.wide'),
                            child: sidebar,
                          ),
                        ),
                        Expanded(child: _buildListBody(state, wide: isWide)),
                      ],
                    )
                  : _buildListBody(state, wide: isWide),
            );
          },
        );
      },
    );
  }

  List<Widget> _toolbarActions() {
    return [
      if (widget.onCreateNote != null)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            key: const Key('notes.create.toolbar'),
            onPressed: widget.onCreateNote,
            icon: const Icon(Icons.add),
            label: const Text('New note'),
          ),
        ),
      if (widget.onUploadFile != null)
        IconButton(
          key: const Key('notes.create.upload.toolbar'),
          tooltip: 'Upload file',
          icon: const Icon(Icons.upload_file),
          onPressed: widget.onUploadFile,
        ),
      if (widget.onSearch != null)
        IconButton(
          key: const Key('shell.search'),
          tooltip: 'Search',
          icon: const Icon(Icons.search),
          onPressed: widget.onSearch,
        ),
      IconButton(
        key: const Key('shell.refresh'),
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh),
        onPressed: widget.controller.refresh,
      ),
      if (widget.onAccount != null)
        IconButton(
          key: const Key('shell.account'),
          tooltip: 'Account',
          icon: const Icon(Icons.account_circle),
          onPressed: widget.onAccount,
        ),
      const SizedBox(width: 4),
    ];
  }

  Widget _buildCreateMenu() {
    return MenuAnchor(
      key: const Key('notes.create.menu'),
      menuChildren: [
        MenuItemButton(
          key: const Key('notes.create.note'),
          leadingIcon: const Icon(Icons.note_add_outlined),
          onPressed: widget.onCreateNote,
          child: const Text('New note'),
        ),
        if (widget.onCreateFolder != null)
          MenuItemButton(
            key: const Key('notes.create.folder'),
            leadingIcon: const Icon(Icons.create_new_folder_outlined),
            onPressed: widget.onCreateFolder,
            child: const Text('New folder'),
          ),
        if (widget.onUploadFile != null)
          MenuItemButton(
            key: const Key('notes.create.upload'),
            leadingIcon: const Icon(Icons.upload_file_outlined),
            onPressed: widget.onUploadFile,
            child: const Text('Upload file'),
          ),
      ],
      builder: (context, menuController, child) {
        return FloatingActionButton(
          key: const Key('notes.create'),
          tooltip: 'Create',
          onPressed: () {
            if (menuController.isOpen) {
              menuController.close();
            } else {
              menuController.open();
            }
          },
          child: const Icon(Icons.add),
        );
      },
    );
  }

  Widget _buildListBody(NotesListState state, {required bool wide}) {
    if (state.items.isEmpty && (state.isLoadingFirst || !_fetchStarted)) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = state.error;
    final showEmpty =
        !state.isLoadingFirst && state.items.isEmpty && error == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFilterBar(state),
        if (error != null)
          ErrorStrip(
            key: const Key('notes.error'),
            message: describeError(error, fallback: 'Could not load notes.'),
            onRetry: widget.controller.refresh,
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: widget.controller.refresh,
            child: showEmpty
                ? _buildEmpty(state)
                : ListView.separated(
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
                        selected: note.id == widget.selectedNoteId,
                        // The path is redundant when every row shares it.
                        showPath: note.path != state.selectedPath,
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
  }

  /// Folder and tag scope chips. Renders nothing when the list is
  /// unscoped so the list sits flush under the app bar.
  Widget _buildFilterBar(NotesListState state) {
    final path = state.selectedPath;
    final tag = state.selectedTag;
    if (path == null && tag == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (path != null)
            InputChip(
              key: const Key('notes.filter.folder'),
              avatar: const Icon(Icons.folder_outlined),
              label: Text('Folder: ${_folderLabel(path)}'),
              deleteIcon: const Icon(
                Icons.close,
                key: Key('notes.filter.folder.clear'),
              ),
              deleteButtonTooltipMessage: 'Show all folders',
              onDeleted: () => widget.controller.selectFolder(null),
            ),
          if (tag != null)
            InputChip(
              key: const Key('notes.filter.tag'),
              avatar: const Icon(Icons.tag),
              label: Text('Tag: $tag'),
              deleteIcon: const Icon(
                Icons.close,
                key: Key('notes.filter.tag.clear'),
              ),
              deleteButtonTooltipMessage: 'Clear tag filter',
              onDeleted: () => widget.controller.selectTag(null),
            ),
        ],
      ),
    );
  }

  /// The empty placeholder, laid out inside a scrollable so the
  /// surrounding [RefreshIndicator] still responds to a pull.
  Widget _buildEmpty(NotesListState state) {
    final tag = state.selectedTag;
    final path = state.selectedPath;
    final newNote = widget.onCreateNote == null
        ? null
        : FilledButton.tonalIcon(
            key: const Key('notes.empty.create'),
            onPressed: widget.onCreateNote,
            icon: const Icon(Icons.add),
            label: const Text('New note'),
          );
    final Widget empty;
    if (tag != null) {
      empty = EmptyState(
        key: const Key('notes.empty'),
        icon: Icons.tag,
        title: 'No notes tagged #$tag',
        message: path == null
            ? 'Nothing in the vault carries this tag.'
            : 'Nothing in ${_folderLabel(path)} carries this tag.',
        action: TextButton(
          key: const Key('notes.empty.clearFilter'),
          onPressed: () => widget.controller.selectTag(null),
          child: const Text('Clear filter'),
        ),
      );
    } else if (path != null) {
      empty = EmptyState(
        key: const Key('notes.empty'),
        icon: Icons.folder_open_outlined,
        title: 'Nothing in ${_folderLabel(path)}',
        message: 'Notes you create here land in this folder.',
        action: newNote,
      );
    } else {
      empty = EmptyState(
        key: const Key('notes.empty'),
        icon: Icons.note_outlined,
        title: 'No notes yet',
        message: 'Notes you and your agents write show up here.',
        action: newNote,
      );
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [SliverFillRemaining(hasScrollBody: false, child: empty)],
    );
  }
}

/// Narrow-layout bottom nav: three always-visible destinations replacing
/// the AppBar hamburger + icon actions the mobile UX review flagged as
/// cramped. These are one-shot actions, not persistent tabs — there is no
/// "selected" state to track — so this is a plain [BottomAppBar] row
/// rather than a [NavigationBar]/[BottomNavigationBar], which both assume
/// a currently-selected destination.
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.hasFolders,
    required this.onSearch,
    required this.onFolders,
    required this.onAccount,
  });

  final bool hasFolders;
  final VoidCallback? onSearch;
  final VoidCallback onFolders;
  final VoidCallback? onAccount;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _BottomNavItem(
            itemKey: const Key('notes.bottomNav.search'),
            icon: Icons.search,
            label: 'Search',
            onTap: onSearch,
          ),
          _BottomNavItem(
            itemKey: const Key('notes.bottomNav.folders'),
            icon: Icons.folder_outlined,
            label: 'Folders',
            onTap: hasFolders ? onFolders : null,
          ),
          _BottomNavItem(
            itemKey: const Key('notes.bottomNav.account'),
            icon: Icons.account_circle_outlined,
            label: 'Account',
            onTap: onAccount,
          ),
        ],
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.itemKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key itemKey;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: itemKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

class _NoteTile extends StatefulWidget {
  const _NoteTile({
    required this.note,
    required this.wide,
    required this.selected,
    required this.showPath,
    required this.onDelete,
    this.onTap,
  });

  final NoteMeta note;

  /// Whether the row is laid out wide enough for hover-to-reveal delete —
  /// on narrow/touch layouts, long-press/right-click (via [MenuAnchor])
  /// remains the only delete affordance.
  final bool wide;

  /// Whether this is the note open beside the list.
  final bool selected;

  /// Whether to show the folder path in the metadata line. `false` when
  /// the list is already scoped to that folder (every row would repeat it).
  /// Root notes have no path to show either way.
  final bool showPath;

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
    final metaStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final showPath = widget.showPath && note.path.isNotEmpty;
    final tile = ListTile(
      key: Key('notes.tile.${note.id}'),
      selected: widget.selected,
      title: Text(
        note.title.isEmpty ? '(untitled)' : note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (note.excerpt.isNotEmpty)
            Text(note.excerpt, maxLines: 1, overflow: TextOverflow.ellipsis),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  // A Wrap rather than a Row so a long path or many tags
                  // spill to a second line instead of overflowing.
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (showPath)
                        Text(
                          note.path,
                          key: Key('notes.tile.${note.id}.path'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      if (showPath && note.tags.isNotEmpty)
                        Text('·', style: metaStyle),
                      for (final tag in note.tags)
                        Text('#$tag', style: metaStyle),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(formatRelativeNoteTime(note.updatedAt), style: metaStyle),
              ],
            ),
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
