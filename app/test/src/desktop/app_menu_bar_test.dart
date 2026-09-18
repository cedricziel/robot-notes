import 'package:app/src/desktop/app_menu_actions.dart';
import 'package:app/src/desktop/app_menu_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flattens a serialized menu tree into `label -> enabled`, walking
/// submenus, so assertions don't depend on grouping or divider placement.
Map<String, bool> _flatten(List<Object?> items) {
  final out = <String, bool>{};
  for (final raw in items) {
    final item = raw! as Map<Object?, Object?>;
    if (item['isDivider'] == true) continue;
    final label = item['label'] as String?;
    if (label != null && label.isNotEmpty) {
      out[label] = item['enabled'] as bool? ?? true;
    }
    final children = item['children'] as List<Object?>?;
    if (children != null) out.addAll(_flatten(children));
  }
  return out;
}

/// Every item in [menus], depth first, through submenus and groups.
Iterable<PlatformMenuItem> _walk(List<PlatformMenuItem> menus) sync* {
  for (final item in menus) {
    yield item;
    if (item is PlatformMenu) yield* _walk(item.menus);
    if (item is PlatformMenuItemGroup) yield* _walk(item.members);
  }
}

/// Finds the [PlatformMenuItem] labelled [label] anywhere in [menus].
PlatformMenuItem _item(List<PlatformMenuItem> menus, String label) =>
    _walk(menus).firstWhere(
      (item) => item.label == label,
      orElse: () => throw StateError('no menu item "$label"'),
    );

void main() {
  group('buildAppMenus', () {
    test('has the standard macOS top-level menus in order', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);

      final menus = buildAppMenus(actions, onCloseWindow: () {});

      expect(menus.map((m) => m.label), [
        'robot-notes',
        'File',
        'Edit',
        'View',
        'Note',
        'Window',
      ]);
    });

    test('items with no handler are disabled; registering enables them', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);

      var menus = buildAppMenus(actions);
      expect(_item(menus, 'New Note').onSelected, isNull);
      expect(_item(menus, 'Save').onSelected, isNull);
      expect(_item(menus, 'Edit Note').onSelected, isNull);

      var created = false;
      actions.setShell(
        Object(),
        ShellMenuHandlers(newNote: () => created = true),
      );
      actions.setNote(Object(), NoteMenuHandlers(save: () {}));

      menus = buildAppMenus(actions);
      _item(menus, 'New Note').onSelected!();
      expect(created, isTrue);
      expect(_item(menus, 'Save').onSelected, isNotNull);
      expect(_item(menus, 'Edit Note').onSelected, isNull);
    });

    test('shows the app\'s keyboard shortcuts on the matching items', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final menus = buildAppMenus(actions, onCloseWindow: () {});

      SingleActivator shortcut(String label) =>
          _item(menus, label).shortcut! as SingleActivator;

      expect(shortcut('New Note').trigger, LogicalKeyboardKey.keyN);
      expect(shortcut('New Note').meta, isTrue);
      expect(shortcut('New Folder…').shift, isTrue);
      expect(shortcut('Save').trigger, LogicalKeyboardKey.keyS);
      expect(shortcut('Search').trigger, LogicalKeyboardKey.keyK);
      expect(shortcut('Refresh').trigger, LogicalKeyboardKey.keyR);
      expect(shortcut('Edit Note').trigger, LogicalKeyboardKey.keyE);
      expect(shortcut('Account…').trigger, LogicalKeyboardKey.comma);
      expect(shortcut('Close Window').trigger, LogicalKeyboardKey.keyW);
    });

    test('Close Window is only offered with a handler', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);

      expect(
        () => _item(buildAppMenus(actions), 'Close Window'),
        throwsStateError,
      );
      var closed = false;
      final menus = buildAppMenus(actions, onCloseWindow: () => closed = true);
      _item(menus, 'Close Window').onSelected!();
      expect(closed, isTrue);
    });

    test('carries the standard provided items (About, Quit, Hide…)', () {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final menus = buildAppMenus(actions);

      final provided = _walk(
        menus,
      ).whereType<PlatformProvidedMenuItem>().map((item) => item.type).toSet();
      expect(
        provided,
        containsAll(<PlatformProvidedMenuItemType>[
          PlatformProvidedMenuItemType.about,
          PlatformProvidedMenuItemType.quit,
          PlatformProvidedMenuItemType.hide,
          PlatformProvidedMenuItemType.toggleFullScreen,
          PlatformProvidedMenuItemType.minimizeWindow,
        ]),
      );
    });
  });

  group('Edit menu', () {
    testWidgets('forwards text-editing intents to the focused field', (
      tester,
    ) async {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(controller: controller, autofocus: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.selection.isCollapsed, isTrue);

      _item(buildAppMenus(actions), 'Select All').onSelected!();
      await tester.pump();

      expect(controller.selection.start, 0);
      expect(controller.selection.end, 'hello world'.length);
    });

    testWidgets('is harmless when nothing has focus', (tester) async {
      final actions = AppMenuActions();
      addTearDown(actions.dispose);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      FocusManager.instance.primaryFocus?.unfocus();

      expect(
        () => _item(buildAppMenus(actions), 'Copy').onSelected!(),
        returnsNormally,
      );
    });
  });

  group('menuOwnsShortcut', () {
    test('claims the ⌘ chords on menu items and nothing else', () {
      expect(
        menuOwnsShortcut(
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
        ),
        isTrue,
      );
      expect(
        menuOwnsShortcut(
          const SingleActivator(
            LogicalKeyboardKey.keyN,
            meta: true,
            shift: true,
          ),
        ),
        isTrue,
      );
      expect(
        menuOwnsShortcut(
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
        ),
        isTrue,
      );
      // Ctrl chords are the Windows/Linux spelling: the menu never sees
      // them, so they stay in the app.
      expect(
        menuOwnsShortcut(
          const SingleActivator(LogicalKeyboardKey.keyN, control: true),
        ),
        isFalse,
      );
      // ⇧⌘F opens search in-app but is not on any menu item.
      expect(
        menuOwnsShortcut(
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            meta: true,
            shift: true,
          ),
        ),
        isFalse,
      );
      // Edit-menu chords are deliberately left to the text fields.
      expect(
        menuOwnsShortcut(
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
        ),
        isFalse,
      );
      expect(
        menuOwnsShortcut(const SingleActivator(LogicalKeyboardKey.escape)),
        isFalse,
      );
    });
  });

  group('withoutMenuOwnedShortcuts', () {
    const bindings = <ShortcutActivator, String>{
      SingleActivator(LogicalKeyboardKey.keyN, meta: true): 'new-meta',
      SingleActivator(LogicalKeyboardKey.keyN, control: true): 'new-ctrl',
      SingleActivator(LogicalKeyboardKey.escape): 'close',
    };

    test('drops the menu-owned chords on the macOS desktop build', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      expect(withoutMenuOwnedShortcuts(bindings).values, ['new-ctrl', 'close']);
    });

    test('returns the bindings untouched elsewhere', () {
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(withoutMenuOwnedShortcuts(bindings), same(bindings));
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('AppMenuBar', () {
    late List<Object?> sentMenus;
    late int setMenusCalls;

    setUp(() {
      sentMenus = <Object?>[];
      setMenusCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, (call) async {
            if (call.method == 'Menu.setMenus') {
              setMenusCalls++;
              final arg = call.arguments as Map<Object?, Object?>;
              sentMenus = arg['0']! as List<Object?>;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, null);
    });

    /// Runs [body] with the target platform pinned, resetting it inline:
    /// the test binding checks the override is clear before tearDowns.
    Future<void> onPlatform(
      TargetPlatform platform,
      Future<void> Function() body,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('installs nothing off macOS', (tester) async {
      await onPlatform(TargetPlatform.android, () async {
        final actions = AppMenuActions();
        addTearDown(actions.dispose);

        await tester.pumpWidget(
          AppMenuBar(actions: actions, child: const SizedBox.shrink()),
        );

        expect(find.byType(PlatformMenuBar), findsNothing);
        expect(setMenusCalls, 0);
      });
    });

    testWidgets('on macOS sends the menu and re-sends it as handlers change', (
      tester,
    ) async {
      await onPlatform(TargetPlatform.macOS, () async {
        final actions = AppMenuActions();
        addTearDown(actions.dispose);

        await tester.pumpWidget(
          AppMenuBar(
            actions: actions,
            onCloseWindow: () {},
            child: const SizedBox.shrink(),
          ),
        );
        await tester.pump();

        expect(find.byType(PlatformMenuBar), findsOneWidget);
        expect(setMenusCalls, greaterThanOrEqualTo(1));
        var flat = _flatten(sentMenus);
        expect(flat['File'], isTrue);
        expect(flat['New Note'], isFalse);
        expect(flat['Save'], isFalse);
        expect(flat['Close Window'], isTrue);

        final before = setMenusCalls;
        actions.setShell(Object(), ShellMenuHandlers(newNote: () {}));
        await tester.pump();

        expect(setMenusCalls, greaterThan(before));
        flat = _flatten(sentMenus);
        expect(flat['New Note'], isTrue);
        expect(flat['Save'], isFalse);
      });
    });
  });
}
