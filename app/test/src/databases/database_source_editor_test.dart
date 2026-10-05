import 'package:app/src/databases/database_source_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  testWidgets('tag sources require a value and never fall back to folders', (
    tester,
  ) async {
    DatabaseSource? source;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseSourceEditor(
            initialSource: const DatabaseSource.folder(
              'Projects',
              includeSubfolders: false,
            ),
            onChanged: (value) => source = value,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('databaseSource.kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tag').last);
    await tester.pumpAndSettle();
    expect(source, isNull);
    await tester.enterText(
      find.byKey(const Key('databaseSource.tag')),
      'project',
    );
    expect(source, const DatabaseSource.tag('project'));
    await tester.enterText(find.byKey(const Key('databaseSource.tag')), ' ');
    expect(source, isNull);
  });
}
