import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../realtime/ws_client.dart';
import '../widgets/adaptive.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_strip.dart';
import 'database_board_view.dart';
import 'database_controller.dart';
import 'database_list_view.dart';
import 'database_table_view.dart';
import 'databases_controller.dart';
import 'schema_editor_screen.dart';

/// The `/databases/{id}` route's content: title, view switcher, New row and
/// schema editor actions, and the table/list/board rendering for the
/// selected view — task 5.1-5.4 of `add-database-views`.
///
/// Driven entirely by [controller]; this widget owns no database state of
/// its own beyond what [DatabaseController] already tracks, matching
/// [NoteScreen]'s split with [NoteController].
class DatabaseScreen extends StatefulWidget {
  const DatabaseScreen({
    required this.controller,
    this.onClose,
    this.onOpenRow,
    this.onOpenSchemaEditor,
    this.onViewChanged,
    super.key,
  });

  final DatabaseController controller;

  /// Called when the user dismisses the screen. Defaults to a plain
  /// [Navigator] pop so pushing this widget directly (as a test might)
  /// keeps working without a router.
  final VoidCallback? onClose;

  /// Called with a row's note id when the user taps its title, a list row,
  /// or a board card.
  final ValueChanged<String>? onOpenRow;

  /// Called when the user taps the schema editor action. Task 6.2/6.3
  /// build the real editor; until then this is a stub button that only
  /// fires the callback (or, with none given, is simply omitted).
  final VoidCallback? onOpenSchemaEditor;

  /// Called whenever the resolved view name changes — including the
  /// "unknown view falls back to the default" case — so the caller (the
  /// router) can rewrite the URL's `?view=` to match what's actually
  /// showing.
  final ValueChanged<String>? onViewChanged;

  @override
  State<DatabaseScreen> createState() => _DatabaseScreenState();
}

class _DatabaseScreenState extends State<DatabaseScreen> {
  String? _lastAnnouncedView;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // Defer the initial load past the first frame, like NotesListScreen,
    // so a test observing the loading state gets a chance to attach its
    // own listener first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.load();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final name = widget.controller.value.viewName;
    if (name != null && name != _lastAnnouncedView) {
      _lastAnnouncedView = name;
      widget.onViewChanged?.call(name);
    }
    if (mounted) setState(() {});
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _promptNewRow() async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => const _NewRowDialog(),
    );
    if (title == null || title.trim().isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final note = await widget.controller.createRow(title.trim());
      if (!mounted) return;
      widget.onOpenRow?.call(note.id);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(describeError(e, fallback: 'Could not create row.')),
        ),
      );
    }
  }

  Future<String?> _onCellCommit(
    String noteId,
    String key,
    PropertyPatch patch,
  ) => widget.controller.patchProperty(
    noteId,
    set: patch.set,
    unset: patch.unset,
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final definition = state.definition;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          definition?.title ?? 'Database',
          key: const Key('database.title'),
        ),
        leading: IconButton(
          key: const Key('database.close'),
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: _close,
        ),
        actions: [
          if (definition != null)
            IconButton(
              key: const Key('database.newRow'),
              icon: const Icon(Icons.add),
              tooltip: 'New row',
              onPressed: _promptNewRow,
            ),
          IconButton(
            key: const Key('database.schemaEditor'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Edit schema',
            onPressed: widget.onOpenSchemaEditor,
          ),
        ],
      ),
      body: _body(context, state),
    );
  }

  Widget _body(BuildContext context, DatabaseScreenState state) {
    switch (state.mode) {
      case DatabaseScreenMode.notFound:
        return const EmptyState(
          key: Key('database.notFound'),
          icon: Icons.search_off,
          title: 'Database not found',
          message:
              "This database doesn't exist, or you no longer have access to it.",
        );
      case DatabaseScreenMode.error:
        final def = state.definition;
        if (def == null) {
          return Center(
            child: ErrorStrip(
              message: describeError(
                state.error ?? 'error',
                fallback: 'Could not load this database.',
              ),
              onRetry: widget.controller.load,
            ),
          );
        }
        return Column(
          children: [
            ErrorStrip(
              message: describeError(
                state.error ?? 'error',
                fallback: 'Could not load this database.',
              ),
              onRetry: widget.controller.load,
            ),
            Expanded(child: _content(context, state, def)),
          ],
        );
      case DatabaseScreenMode.loading:
        if (state.definition == null) {
          return const Center(
            key: Key('database.loading'),
            child: CircularProgressIndicator.adaptive(),
          );
        }
        return _content(context, state, state.definition!);
      case DatabaseScreenMode.ready:
        final def = state.definition;
        if (def == null) {
          return const Center(child: CircularProgressIndicator.adaptive());
        }
        return _content(context, state, def);
    }
  }

  Widget _content(
    BuildContext context,
    DatabaseScreenState state,
    DatabaseDefinition definition,
  ) {
    if (definition.views.isEmpty) {
      return const EmptyState(
        key: Key('database.noViews'),
        icon: Icons.view_column_outlined,
        title: 'No views yet',
        message: 'Add a view in the schema editor to see rows here.',
      );
    }
    final view = state.view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ViewSwitcher(
          views: definition.views,
          selected: state.viewName,
          onSelect: widget.controller.selectView,
        ),
        if (state.leftViewNotice != null)
          _LeftViewBanner(
            notice: state.leftViewNotice!,
            onUndo: widget.controller.undoLeftView,
            onDismiss: widget.controller.dismissLeftViewNotice,
          ),
        Expanded(
          child: view == null
              ? const EmptyState(
                  icon: Icons.view_column_outlined,
                  title: 'No views yet',
                )
              : _viewBody(context, state, definition, view),
        ),
      ],
    );
  }

  Widget _viewBody(
    BuildContext context,
    DatabaseScreenState state,
    DatabaseDefinition definition,
    ViewDefinition view,
  ) {
    if (state.isLoadingFirst) {
      return const Center(
        key: Key('database.view.loading'),
        child: CircularProgressIndicator.adaptive(),
      );
    }
    switch (view.type) {
      case ViewType.table:
        if (state.rows.isEmpty) {
          return const EmptyState(
            key: Key('database.empty'),
            icon: Icons.inbox_outlined,
            title: 'No rows yet',
          );
        }
        return DatabaseTableView(
          definition: definition,
          view: view,
          rows: state.rows,
          hasMore: state.hasMore,
          isLoadingMore: state.isLoadingMore,
          onLoadMore: widget.controller.loadMore,
          onCommit: _onCellCommit,
          api: widget.controller.api,
          onOpenRow: widget.onOpenRow,
        );
      case ViewType.list:
        if (state.rows.isEmpty) {
          return const EmptyState(
            key: Key('database.empty'),
            icon: Icons.inbox_outlined,
            title: 'No rows yet',
          );
        }
        return DatabaseListView(
          definition: definition,
          view: view,
          rows: state.rows,
          hasMore: state.hasMore,
          isLoadingMore: state.isLoadingMore,
          onLoadMore: widget.controller.loadMore,
          onOpenRow: widget.onOpenRow,
        );
      case ViewType.board:
        final columns = state.columns ?? const <BoardColumn>[];
        if (columns.every((c) => c.count == 0)) {
          return const EmptyState(
            key: Key('database.empty'),
            icon: Icons.inbox_outlined,
            title: 'No rows yet',
          );
        }
        return DatabaseBoardView(
          view: view,
          columns: columns,
          onLoadMoreColumn: widget.controller.loadMoreColumn,
          onMoveCard: widget.controller.moveCard,
          onOpenRow: widget.onOpenRow,
        );
    }
  }
}

class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({
    required this.views,
    required this.selected,
    required this.onSelect,
  });

  final List<ViewDefinition> views;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final view in views)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('database.view.${view.name}'),
                  label: Text(view.name),
                  selected: view.name == selected,
                  onSelected: (_) => onSelect(view.name),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LeftViewBanner extends StatelessWidget {
  const _LeftViewBanner({
    required this.notice,
    required this.onUndo,
    required this.onDismiss,
  });

  final LeftViewNotice notice;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '"${notice.title}" moved out of this view',
                key: const Key('database.leftView.message'),
              ),
            ),
            TextButton(
              key: const Key('database.leftView.undo'),
              onPressed: onUndo,
              child: const Text('Undo'),
            ),
            IconButton(
              key: const Key('database.leftView.dismiss'),
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _NewRowDialog extends StatefulWidget {
  const _NewRowDialog();

  @override
  State<_NewRowDialog> createState() => _NewRowDialogState();
}

class _NewRowDialogState extends State<_NewRowDialog> {
  String _title = '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog.adaptive(
      title: const Text('New row'),
      content: AdaptiveDialogTextField(
        key: const Key('database.newRow.input'),
        label: 'Title',
        hint: 'e.g. Ship the release',
        onChanged: (v) => _title = v,
      ),
      actions: [
        adaptiveDialogAction(
          context,
          key: const Key('database.newRow.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        adaptiveDialogAction(
          context,
          key: const Key('database.newRow.confirm'),
          primary: true,
          onPressed: () => Navigator.of(context).pop(_title),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Owns a [DatabasesController] and a [DatabaseController] for one open
/// `/databases/:id` route and wires them into [DatabaseScreen] — the
/// counterpart to `NoteRoute` for notes. Kept keyed on [databaseId] by the
/// caller so navigating between databases remounts state instead of
/// reusing a controller bound to the old id.
class DatabaseRoute extends StatefulWidget {
  const DatabaseRoute({
    required this.api,
    required this.ws,
    required this.databaseId,
    this.viewName,
    this.onClose,
    this.onOpenNote,
    this.onOpenSchemaEditor,
    this.onViewChanged,
    super.key,
  });

  final RobotNotesClient api;
  final RobotNotesWsClient ws;
  final String databaseId;
  final String? viewName;
  final VoidCallback? onClose;
  final ValueChanged<String>? onOpenNote;
  final VoidCallback? onOpenSchemaEditor;
  final ValueChanged<String>? onViewChanged;

  @override
  State<DatabaseRoute> createState() => _DatabaseRouteState();
}

class _DatabaseRouteState extends State<DatabaseRoute> {
  late final DatabasesController _databases;
  late final DatabaseController _controller;

  @override
  void initState() {
    super.initState();
    _databases = DatabasesController(api: widget.api, events: widget.ws.events);
    _controller = DatabaseController(
      api: widget.api,
      databases: _databases,
      databaseId: widget.databaseId,
      initialView: widget.viewName,
      events: widget.ws.events,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _databases.dispose();
    super.dispose();
  }

  /// Opens the schema editor as a full-screen route on top of this one, per
  /// design.md's "Schema editor is a full-screen form" — wired here rather
  /// than left as a bare stub, unless [DatabaseRoute.onOpenSchemaEditor]
  /// overrides it. Saving forces the controller to reload the definition
  /// (bypassing the shared cache) so the screen picks up the change
  /// immediately, then pops the editor.
  void _openSchemaEditor() {
    final definition = _controller.value.definition;
    if (definition == null) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SchemaEditorScreen(
            definition: definition,
            api: _controller.api,
            onSaved: (_) {
              Navigator.of(context).pop();
              unawaited(_controller.load(forceRefresh: true));
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DatabaseScreen(
      controller: _controller,
      onClose: widget.onClose,
      onOpenRow: widget.onOpenNote,
      onOpenSchemaEditor: widget.onOpenSchemaEditor ?? _openSchemaEditor,
      onViewChanged: widget.onViewChanged,
    );
  }
}
