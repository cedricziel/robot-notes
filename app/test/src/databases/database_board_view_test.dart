import 'package:app/src/databases/database_board_view.dart';
import 'package:app/src/databases/database_controller.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

const _now2025 = '2025-01-01T00:00:00.000Z';

DatabaseRow _row(String id, String title) => DatabaseRow(
  id: id,
  title: title,
  version: 1,
  createdAt: DateTime.parse(_now2025),
  updatedAt: DateTime.parse(_now2025),
);

const _view = ViewDefinition(
  name: 'Kanban',
  type: ViewType.board,
  groupBy: 'status',
);

void main() {
  testWidgets('renders columns with header counts and a Load more button '
      'when the column has more than is loaded', (tester) async {
    final columns = [
      BoardColumn(
        label: 'Idea',
        value: 'Idea',
        count: 3,
        items: [_row('1', 'a')],
      ),
      const BoardColumn(label: 'No value', value: null, isNoValue: true),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseBoardView(
            view: _view,
            columns: columns,
            onLoadMoreColumn: (_) {},
            onMoveCard: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('Idea (3)'), findsOneWidget);
    expect(find.text('No value (0)'), findsOneWidget);
    expect(
      find.byKey(const Key('database.board.column.Idea.loadMore')),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping Load more calls onLoadMoreColumn with the column value',
    (tester) async {
      Object? loaded = 'unset';
      final columns = [
        BoardColumn(
          label: 'Idea',
          value: 'Idea',
          count: 3,
          items: [_row('1', 'a')],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DatabaseBoardView(
              view: _view,
              columns: columns,
              onLoadMoreColumn: (v) => loaded = v,
              onMoveCard: (_, _) {},
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const Key('database.board.column.Idea.loadMore')),
      );
      expect(loaded, 'Idea');
    },
  );

  testWidgets(
    'dragging a card from one column to another calls onMoveCard with the '
    'target column value',
    (tester) async {
      String? movedNote;
      Object? movedTo = 'unset';
      final columns = [
        BoardColumn(
          label: 'Idea',
          value: 'Idea',
          count: 1,
          items: [_row('1', 'a')],
        ),
        const BoardColumn(label: 'Done', value: 'Done', count: 0),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DatabaseBoardView(
              view: _view,
              columns: columns,
              onLoadMoreColumn: (_) {},
              onMoveCard: (noteId, columnValue) {
                movedNote = noteId;
                movedTo = columnValue;
              },
            ),
          ),
        ),
      );

      final card = find.byKey(const Key('database.board.card.1.draggable'));
      final target = find.byKey(const Key('database.board.column.Done'));

      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(movedNote, '1');
      expect(movedTo, 'Done');
    },
  );

  testWidgets('dropping a card on "No value" unsets the grouped property', (
    tester,
  ) async {
    Object? movedTo = 'unset';
    final columns = [
      BoardColumn(
        label: 'Idea',
        value: 'Idea',
        count: 1,
        items: [_row('1', 'a')],
      ),
      const BoardColumn(label: 'No value', value: null, isNoValue: true),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseBoardView(
            view: _view,
            columns: columns,
            onLoadMoreColumn: (_) {},
            onMoveCard: (_, columnValue) => movedTo = columnValue,
          ),
        ),
      ),
    );

    final card = find.byKey(const Key('database.board.card.1.draggable'));
    final target = find.byKey(const Key('database.board.column.No value'));

    final gesture = await tester.startGesture(tester.getCenter(card));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(movedTo, isNull);
  });
}
