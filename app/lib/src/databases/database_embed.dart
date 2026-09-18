import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../realtime/ws_client.dart';
import 'database_table_view.dart' show builtinPropertyKeys;
import 'databases_controller.dart';
import 'property_value_view.dart';

/// The `![[Title]]` / `![[Title#View]]` embed (task 7.2): a read-only
/// rendering of a registered database's named view (or its default view)
/// limited to the first 50 rows, with a "Show all" link and row titles
/// linking to their notes. Resolves [title] against [databases]' loaded
/// list (NFC-normalised, case-insensitive — see
/// `DatabasesController.resolveByTitle`) and [view] against the resolved
/// database's views; either failing to resolve renders the literal source
/// text, per the "Database embeds render in view mode" spec.
///
/// Debounces a re-query on `changed` events with the same 1 s cadence as
/// the database screen ([DatabasesController.debounceDuration]).
class DatabaseEmbed extends StatefulWidget {
  const DatabaseEmbed({
    required this.title,
    required this.databases,
    required this.api,
    this.view,
    this.events,
    this.debounceScheduler,
    this.onOpenNote,
    this.onShowAll,
    super.key,
  });

  /// The embed's `Title` as written in the source — resolved against
  /// database titles, never shown verbatim except in the literal fallback.
  final String title;

  /// The embed's `#View`, if given. `null` means the database's default
  /// (first) view.
  final String? view;

  final DatabasesController databases;
  final RobotNotesClient api;

  /// The realtime event stream to debounce a re-query on. `null` disables
  /// live refresh (e.g. a context with no realtime connection).
  final Stream<RealtimeEvent>? events;

  /// Overridable for tests; defaults to a real delay, matching
  /// `DatabasesController.debounceDuration` (1 s).
  final Future<void> Function(Duration)? debounceScheduler;

  /// Called with a row's note id when its title is tapped.
  final ValueChanged<String>? onOpenNote;

  /// Called with the resolved database id and view name when "Show all" is
  /// tapped — the caller navigates to `/databases/{id}?view=<name>`.
  final void Function(String databaseId, String viewName)? onShowAll;

  static const Duration debounceDuration = DatabasesController.debounceDuration;
  static const int rowLimit = 50;

  @override
  State<DatabaseEmbed> createState() => _DatabaseEmbedState();
}

enum _EmbedStatus { loading, resolved, unresolved, error }

class _DatabaseEmbedState extends State<DatabaseEmbed> {
  _EmbedStatus _status = _EmbedStatus.loading;
  DatabaseDefinition? _definition;
  ViewDefinition? _resolvedView;
  List<DatabaseRow> _rows = const <DatabaseRow>[];

  StreamSubscription<RealtimeEvent>? _sub;
  bool _disposed = false;
  int _debounceGen = 0;
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    final events = widget.events;
    if (events != null) {
      _sub = events.listen(_onEvent);
    }
  }

  @override
  void didUpdateWidget(covariant DatabaseEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title || oldWidget.view != widget.view) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }

  String get _literalSource => widget.view == null
      ? '![[${widget.title}]]'
      : '![[${widget.title}#${widget.view}]]';

  Future<void> _load() async {
    final gen = ++_loadGen;
    if (mounted) setState(() => _status = _EmbedStatus.loading);
    final summary = widget.databases.resolveByTitle(widget.title);
    if (summary == null) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _status = _EmbedStatus.unresolved);
      return;
    }
    final DatabaseDefinition definition;
    try {
      definition = await widget.databases.definition(summary.id);
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _status = _EmbedStatus.error);
      return;
    }
    if (definition.views.isEmpty) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _status = _EmbedStatus.unresolved);
      return;
    }
    final requestedView = widget.view;
    ViewDefinition? resolved;
    if (requestedView == null) {
      resolved = definition.views.first;
    } else {
      for (final v in definition.views) {
        if (v.name == requestedView) {
          resolved = v;
          break;
        }
      }
      if (resolved == null) {
        if (!mounted || gen != _loadGen) return;
        setState(() => _status = _EmbedStatus.unresolved);
        return;
      }
    }
    try {
      final page = await widget.api.queryDatabase(
        summary.id,
        view: resolved.name,
        limit: DatabaseEmbed.rowLimit,
      );
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _status = _EmbedStatus.resolved;
        _definition = definition;
        _resolvedView = resolved;
        _rows = page.items;
      });
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _status = _EmbedStatus.error);
    }
  }

  void _onEvent(RealtimeEvent event) {
    if (event is! RealtimeMessage) return;
    if (event.message is! ChangedEvent) return;
    _scheduleDebouncedRefresh();
  }

  void _scheduleDebouncedRefresh() {
    _debounceGen += 1;
    final gen = _debounceGen;
    unawaited(_runDebounced(gen));
  }

  Future<void> _runDebounced(int gen) async {
    final scheduler = widget.debounceScheduler ?? Future<void>.delayed;
    await scheduler(DatabaseEmbed.debounceDuration);
    if (_disposed) return;
    if (_debounceGen != gen) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _EmbedStatus.loading:
        return const SizedBox(
          height: 80,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      case _EmbedStatus.unresolved:
      case _EmbedStatus.error:
        return Text(_literalSource, key: const Key('database.embed.literal'));
      case _EmbedStatus.resolved:
        final definition = _definition!;
        final view = _resolvedView!;
        return _EmbedCard(
          definition: definition,
          view: view,
          rows: _rows,
          onOpenNote: widget.onOpenNote,
          onShowAll: widget.onShowAll == null
              ? null
              : () => widget.onShowAll!(definition.id, view.name),
        );
    }
  }
}

class _EmbedCard extends StatelessWidget {
  const _EmbedCard({
    required this.definition,
    required this.view,
    required this.rows,
    this.onOpenNote,
    this.onShowAll,
  });

  final DatabaseDefinition definition;
  final ViewDefinition view;
  final List<DatabaseRow> rows;
  final ValueChanged<String>? onOpenNote;
  final VoidCallback? onShowAll;

  List<String> get _keys =>
      view.properties ?? definition.properties.keys.toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: Key(
        'database-embed-${definition.title}${view.name.isEmpty ? '' : '#${view.name}'}',
      ),
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    definition.title,
                    key: const Key('database.embed.title'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (onShowAll != null)
                  TextButton(
                    key: const Key('database.embed.showAll'),
                    onPressed: onShowAll,
                    child: const Text('Show all'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              key: const Key('database.embed.scroll'),
              child: view.type == ViewType.board
                  ? _BoardBody(view: view, rows: rows, onOpenNote: onOpenNote)
                  : _FlatBody(
                      definition: definition,
                      keys: _keys,
                      rows: rows,
                      onOpenNote: onOpenNote,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FlatBody extends StatelessWidget {
  const _FlatBody({
    required this.definition,
    required this.keys,
    required this.rows,
    this.onOpenNote,
  });

  final DatabaseDefinition definition;
  final List<String> keys;
  final List<DatabaseRow> rows;
  final ValueChanged<String>? onOpenNote;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Padding(padding: EdgeInsets.all(12), child: Text('No rows'));
    }
    return Table(
      key: const Key('database.embed.table'),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      columnWidths: const {0: IntrinsicColumnWidth()},
      children: [
        for (final row in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: InkWell(
                  key: Key('database.embed.row.${row.id}.title'),
                  onTap: onOpenNote == null ? null : () => onOpenNote!(row.id),
                  child: Text(row.title),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final key in keys)
                      if (!builtinPropertyKeys.contains(key) &&
                          row.properties[key] != null)
                        _Cell(label: key, value: row.properties[key]),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value});

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: PropertyValueView.unrepresentable(value),
    );
  }
}

class _BoardBody extends StatelessWidget {
  const _BoardBody({required this.view, required this.rows, this.onOpenNote});

  final ViewDefinition view;
  final List<DatabaseRow> rows;
  final ValueChanged<String>? onOpenNote;

  @override
  Widget build(BuildContext context) {
    final groupBy = view.groupBy;
    if (groupBy == null) {
      return const Padding(padding: EdgeInsets.all(12), child: Text('No rows'));
    }
    final columns = <String, List<DatabaseRow>>{};
    const noValueLabel = 'No value';
    for (final row in rows) {
      final v = row.properties[groupBy];
      final label = v == null ? noValueLabel : '$v';
      columns.putIfAbsent(label, () => <DatabaseRow>[]).add(row);
    }
    if (columns.isEmpty) {
      return const Padding(padding: EdgeInsets.all(12), child: Text('No rows'));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in columns.entries)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: 160,
                child: Column(
                  key: Key('database.embed.column.${entry.key}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.key,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    for (final row in entry.value)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: InkWell(
                          key: Key('database.embed.row.${row.id}.title'),
                          onTap: onOpenNote == null
                              ? null
                              : () => onOpenNote!(row.id),
                          child: Text(row.title),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
