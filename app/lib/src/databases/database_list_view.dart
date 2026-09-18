import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

/// A `list` view: one line per row with the title and the view's
/// properties rendered as compact, read-only chips (task 5.3). Editing a
/// value happens on the note itself or in the table view — list rows are
/// tap-to-open only, per the spec's "list row navigates to the note" rule.
class DatabaseListView extends StatelessWidget {
  const DatabaseListView({
    required this.definition,
    required this.view,
    required this.rows,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
    this.onOpenRow,
    super.key,
  });

  final DatabaseDefinition definition;
  final ViewDefinition view;
  final List<DatabaseRow> rows;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;
  final ValueChanged<String>? onOpenRow;

  List<String> get _keys =>
      view.properties ?? definition.properties.keys.toList();

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    if (rows.isEmpty) {
      return const Center(child: Text('No rows'));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (metrics.axis == Axis.vertical &&
            metrics.pixels >= metrics.maxScrollExtent - 200) {
          onLoadMore();
        }
        return false;
      },
      child: ListView.builder(
        key: const Key('database.list'),
        itemCount: rows.length + (isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= rows.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final row = rows[index];
          return ListTile(
            key: Key('database.list.row.${row.id}'),
            title: Text(row.title),
            subtitle: keys.isEmpty
                ? null
                : Wrap(
                    spacing: 6,
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
            onTap: onOpenRow == null ? null : () => onOpenRow!(row.id),
          );
        },
      ),
    );
  }

  String _display(Object? value) {
    if (value is List) return value.join(', ');
    return value.toString();
  }
}
