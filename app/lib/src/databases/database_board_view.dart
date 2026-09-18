import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'database_controller.dart';

/// A `board` view: one column per option of the grouped property (in
/// option order) plus a trailing "No value" column, counts from `groups`
/// in each header, per-column "Load more" paging, and drag-and-drop
/// between columns (task 5.4). Uses Flutter's `LongPressDraggable`/
/// `DragTarget` per design.md rather than a third-party reorder package.
class DatabaseBoardView extends StatelessWidget {
  const DatabaseBoardView({
    required this.view,
    required this.columns,
    required this.onLoadMoreColumn,
    required this.onMoveCard,
    this.onOpenRow,
    super.key,
  });

  final ViewDefinition view;
  final List<BoardColumn> columns;
  final ValueChanged<Object?> onLoadMoreColumn;

  /// `(noteId, columnValue)` — `columnValue` is `null` for "No value".
  final void Function(String noteId, Object? columnValue) onMoveCard;
  final ValueChanged<String>? onOpenRow;

  List<String> get _keys => view.properties ?? const <String>[];

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) {
      return const Center(child: Text('No columns'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            height: constraints.maxHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final column in columns)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: 260,
                      child: _BoardColumnWidget(
                        column: column,
                        keys: _keys,
                        onLoadMore: () => onLoadMoreColumn(column.value),
                        onMoveCard: onMoveCard,
                        onOpenRow: onOpenRow,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BoardColumnWidget extends StatelessWidget {
  const _BoardColumnWidget({
    required this.column,
    required this.keys,
    required this.onLoadMore,
    required this.onMoveCard,
    this.onOpenRow,
  });

  final BoardColumn column;
  final List<String> keys;
  final VoidCallback onLoadMore;
  final void Function(String noteId, Object? columnValue) onMoveCard;
  final ValueChanged<String>? onOpenRow;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => onMoveCard(details.data, column.value),
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;
        return Container(
          key: Key('database.board.column.${column.label}'),
          decoration: BoxDecoration(
            color: highlighted
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '${column.label} (${column.count})',
                  key: Key('database.board.column.${column.label}.header'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  key: Key('database.board.column.${column.label}.list'),
                  children: [
                    for (final row in column.items)
                      _BoardCard(row: row, keys: keys, onOpenRow: onOpenRow),
                    if (column.items.length < column.count)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: column.isLoadingMore
                            ? const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : TextButton(
                                key: Key(
                                  'database.board.column.${column.label}.loadMore',
                                ),
                                onPressed: onLoadMore,
                                child: const Text('Load more'),
                              ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BoardCard extends StatelessWidget {
  const _BoardCard({required this.row, required this.keys, this.onOpenRow});

  final DatabaseRow row;
  final List<String> keys;
  final ValueChanged<String>? onOpenRow;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      key: Key('database.board.card.${row.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: InkWell(
        onTap: onOpenRow == null ? null : () => onOpenRow!(row.id),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(row.title),
              if (keys.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final key in keys)
                      if (row.properties[key] != null)
                        Chip(
                          label: Text(_display(row.properties[key])),
                          visualDensity: VisualDensity.compact,
                        ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return LongPressDraggable<String>(
      key: Key('database.board.card.${row.id}.draggable'),
      data: row.id,
      feedback: Material(
        elevation: 4,
        child: SizedBox(width: 240, child: card),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }

  String _display(Object? value) {
    if (value is List) return value.join(', ');
    return value.toString();
  }
}
