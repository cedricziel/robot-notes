import 'package:app/src/desktop/app_menu_actions.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppMenuActions', () {
    test('starts with every handler absent', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);

      expect(actions.shell.newNote, isNull);
      expect(actions.shell.search, isNull);
      expect(actions.note.save, isNull);
      expect(actions.note.close, isNull);
      expect(actions.database.newRow, isNull);
      expect(actions.database.editSchema, isNull);
    });

    test('setShell installs handlers and notifies', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      var notified = 0;
      actions.addListener(() => notified++);
      final owner = Object();

      actions.setShell(owner, ShellMenuHandlers(newNote: () {}));

      expect(actions.shell.newNote, isNotNull);
      expect(notified, 1);
    });

    test('clearShell only withdraws the handlers of the current owner', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final first = Object();
      final second = Object();
      actions.setShell(first, ShellMenuHandlers(refresh: () {}));
      actions.setShell(second, ShellMenuHandlers(search: () {}));

      // The stale owner (a screen disposed after its replacement mounted)
      // must not wipe the replacement's registration.
      actions.clearShell(first);
      expect(actions.shell.search, isNotNull);

      actions.clearShell(second);
      expect(actions.shell.search, isNull);
    });

    test('note handlers follow the same owner rule', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final old = Object();
      final current = Object();
      actions.setNote(old, NoteMenuHandlers(edit: () {}));
      actions.setNote(current, NoteMenuHandlers(save: () {}));

      actions.clearNote(old);
      expect(actions.note.save, isNotNull);
      expect(actions.note.edit, isNull);

      actions.clearNote(current);
      expect(actions.note.save, isNull);
    });

    test('database handlers follow the same owner rule', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final old = Object();
      final current = Object();
      actions.setDatabase(old, DatabaseMenuHandlers(newRow: () {}));
      actions.setDatabase(current, DatabaseMenuHandlers(editSchema: () {}));

      actions.clearDatabase(old);
      expect(actions.database.editSchema, isNotNull);
      expect(actions.database.newRow, isNull);

      actions.clearDatabase(current);
      expect(actions.database.editSchema, isNull);
    });

    test('clearing an owner that never registered notifies nobody', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      var notified = 0;
      actions.addListener(() => notified++);

      actions.clearShell(Object());
      actions.clearNote(Object());

      expect(notified, 0);
    });
  });

  group('notification timing', () {
    testWidgets('a change made during build is announced after the frame', (
      tester,
    ) async {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      var notified = 0;
      actions.addListener(() => notified++);

      // Registers from didChangeDependencies, as the real screens do,
      // underneath a listener that rebuilds on notification.
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: actions,
          builder: (context, _) => _Registrar(actions: actions),
        ),
      );
      expect(tester.takeException(), isNull);

      // Announced once the build phase is over, never during it.
      expect(actions.shell.newNote, isNotNull);
      expect(notified, 1);

      // The listener above rebuilt as a result (a second frame).
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(_Registrar.builds, greaterThanOrEqualTo(2));
    });

    test('a change made outside a frame is announced at once', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      var notified = 0;
      actions.addListener(() => notified++);

      actions.setNote(Object(), NoteMenuHandlers(save: () {}));

      expect(notified, 1);
    });
  });

  group('AppMenuActionsScope', () {
    testWidgets('maybeOf finds the registry above, or null', (tester) async {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      AppMenuActions? inside;
      AppMenuActions? outside;

      await tester.pumpWidget(
        Column(
          textDirection: TextDirection.ltr,
          children: [
            Builder(
              builder: (context) {
                outside = AppMenuActionsScope.maybeOf(context);
                return const SizedBox.shrink();
              },
            ),
            AppMenuActionsScope(
              actions: actions,
              child: Builder(
                builder: (context) {
                  inside = AppMenuActionsScope.maybeOf(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      );

      expect(inside, same(actions));
      expect(outside, isNull);
    });
  });
}

class _Registrar extends StatefulWidget {
  const _Registrar({required this.actions});

  final AppMenuActions actions;

  static int builds = 0;

  @override
  State<_Registrar> createState() => _RegistrarState();
}

class _RegistrarState extends State<_Registrar> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.actions.setShell(this, ShellMenuHandlers(newNote: () {}));
  }

  @override
  void dispose() {
    widget.actions.clearShell(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _Registrar.builds++;
    return const SizedBox.shrink();
  }
}
