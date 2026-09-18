import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../format/note_time.dart';
import 'database_cell_editor.dart';

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
/// scroll paging, and inline cell editing through [DatabaseCellEditor].
class DatabaseTableView extends StatelessWidget {
  const DatabaseTableView({
    required this.definition,
    required this.view,
    required this.rows,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
    required this.onCommit,
    this.onOpenRow,
    super.key,
  });

  final DatabaseDefinition definition;
  final ViewDefinition view;
  final List<DatabaseRow> rows;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;

  /// `(noteId, propertyKey, patch)` — each row binds its own id before
  /// handing a plain [PropertyPatchCommit] down to [DatabaseCellEditor].
  final void Function(String noteId, String propertyKey, PropertyPatch patch)
  onCommit;
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
                                      child: CircularProgressIndicator(
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
    required this.onCommit,
    this.onOpenRow,
    super.key,
  });

  final DatabaseRow row;
  final List<String> keys;
  final void Function(String noteId, String propertyKey, PropertyPatch patch)
  onCommit;
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
                  : DatabaseCellEditor(
                      propertyKey: key,
                      value: row.properties[key],
                      onCommit: (propertyKey, patch) =>
                          onCommit(row.id, propertyKey, patch),
                    ),
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
}
