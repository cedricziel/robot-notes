import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../format/note_time.dart';
import 'property_editor.dart';
import 'property_value_view.dart';
import 'title_search_service.dart';

/// The built-in row fields every view may reference by key, per the
/// `flutter-client` spec's table requirement — read-only regardless of the
/// view's declared `properties`.
const Set<String> builtinPropertyKeys = {
  'title',
  'path',
  'tags',
  'created_at',
  'updated_at',
};

/// A `table` view: a title column plus one column per view key (declared
/// properties, or every property when the view names none), infinite
/// scroll paging, and inline cell editing through [PropertyEditor].
class DatabaseTableView extends StatelessWidget {
  const DatabaseTableView({
    required this.definition,
    required this.view,
    required this.rows,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
    required this.onCommit,
    this.api,
    this.onOpenRow,
    super.key,
  });

  final DatabaseDefinition definition;
  final ViewDefinition view;
  final List<DatabaseRow> rows;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;

  /// `(noteId, propertyKey, patch)` — each row binds its own id and
  /// property key before handing a plain [PropertyCommitCallback] down to
  /// [PropertyEditor]. Returns the server's error message on a rejected
  /// commit (see `DatabaseController.patchProperty`), or `null` on
  /// success.
  final Future<String?> Function(
    String noteId,
    String propertyKey,
    PropertyPatch patch,
  )
  onCommit;

  /// Backs `relation` property pickers' title search, restricted to their
  /// declared target database. `null` disables relation search (cells
  /// still render, but the picker has no suggestions).
  final RobotNotesClient? api;
  final ValueChanged<String>? onOpenRow;

  List<String> get _keys =>
      view.properties ?? definition.properties.keys.toList();

  static const double _colWidth = 180;
  static const double _titleColWidth = 220;

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (metrics.axis == Axis.vertical &&
            metrics.pixels >= metrics.maxScrollExtent - 200) {
          onLoadMore();
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (_titleColWidth + keys.length * _colWidth).clamp(
            constraints.maxWidth,
            double.infinity,
          );
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: constraints.maxHeight,
              child: Column(
                children: [
                  _HeaderRow(keys: keys, definition: definition),
                  const Divider(height: 1),
                  Expanded(
                    child: rows.isEmpty
                        ? const Center(child: Text('No rows'))
                        : ListView.builder(
                            key: const Key('database.table.list'),
                            itemCount: rows.length + (isLoadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= rows.length) {
                                return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator.adaptive(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              final row = rows[index];
                              return _RowWidget(
                                key: ValueKey<String>(row.id),
                                row: row,
                                keys: keys,
                                definition: definition,
                                api: api,
                                onCommit: onCommit,
                                onOpenRow: onOpenRow,
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.keys, required this.definition});

  final List<String> keys;
  final DatabaseDefinition definition;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    return Row(
      children: [
        const SizedBox(
          width: DatabaseTableView._titleColWidth,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text('Title'),
          ),
        ),
        for (final key in keys)
          SizedBox(
            width: DatabaseTableView._colWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text(
                definition.properties[key]?.label ?? _labelFor(key),
                style: style,
              ),
            ),
          ),
      ],
    );
  }

  String _labelFor(String key) {
    switch (key) {
      case 'path':
        return 'Path';
      case 'tags':
        return 'Tags';
      case 'created_at':
        return 'Created';
      case 'updated_at':
        return 'Updated';
      default:
        return key;
    }
  }
}

class _RowWidget extends StatelessWidget {
  const _RowWidget({
    required this.row,
    required this.keys,
    required this.definition,
    required this.onCommit,
    this.api,
    this.onOpenRow,
    super.key,
  });

  final DatabaseRow row;
  final List<String> keys;
  final DatabaseDefinition definition;
  final Future<String?> Function(
    String noteId,
    String propertyKey,
    PropertyPatch patch,
  )
  onCommit;
  final RobotNotesClient? api;
  final ValueChanged<String>? onOpenRow;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: DatabaseTableView._titleColWidth,
          child: InkWell(
            key: Key('database.table.row.${row.id}.title'),
            onTap: onOpenRow == null ? null : () => onOpenRow!(row.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text(row.title, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        for (final key in keys)
          SizedBox(
            width: DatabaseTableView._colWidth,
            child: Container(
              key: row.invalid.contains(key)
                  ? Key('database.table.row.${row.id}.$key.invalid')
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: row.invalid.contains(key)
                  ? BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.errorContainer.withValues(alpha: 0.4),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  : null,
              child: builtinPropertyKeys.contains(key)
                  ? _builtinCell(context, key)
                  : _propertyCell(context, key),
            ),
          ),
      ],
    );
  }

  Widget _builtinCell(BuildContext context, String key) {
    switch (key) {
      case 'title':
        return Text(row.title, overflow: TextOverflow.ellipsis);
      case 'path':
        return Text(row.path, overflow: TextOverflow.ellipsis);
      case 'tags':
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [for (final tag in row.tags) Chip(label: Text(tag))],
        );
      case 'created_at':
        return Tooltip(
          message: formatNoteTimestamp(row.createdAt),
          child: Text(formatRelativeNoteTime(row.createdAt)),
        );
      case 'updated_at':
        return Tooltip(
          message: formatNoteTimestamp(row.updatedAt),
          child: Text(formatRelativeNoteTime(row.updatedAt)),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// Renders [key]'s editor: the real, typed [PropertyEditor] when the
  /// property is declared on [definition], or a read-only
  /// [PropertyValueView] for an undeclared property (a value present in
  /// the row's data but not in the schema — nothing to edit it against).
  Widget _propertyCell(BuildContext context, String key) {
    final propertyDefinition = definition.properties[key];
    if (propertyDefinition == null) {
      return PropertyValueView.unrepresentable(row.properties[key]);
    }
    final apiClient = api;
    TitleSearchService? titleSearchService;
    if (propertyDefinition.type == PropertyType.relation && apiClient != null) {
      final target = propertyDefinition.database;
      titleSearchService = target != null
          ? TitleSearchService.forDatabase(api: apiClient, databaseId: target)
          : TitleSearchService(api: apiClient);
    }
    return PropertyEditor(
      key: Key('database.table.row.${row.id}.$key.editor'),
      propertyKey: key,
      definition: propertyDefinition,
      value: row.properties[key],
      invalid: row.invalid.contains(key),
      titleSearchService: titleSearchService,
      onCommit: (patch) => onCommit(row.id, key, patch),
    );
  }
}
