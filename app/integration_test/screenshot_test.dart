// App Store screenshot capture. Run via `fastlane capture_screenshots`
// (see app/fastlane/Fastfile) against a disposable ephemeral server that
// lane seeds with fictional sample content before launching this test —
// never against a real user's server.
//
// iOS needs the native `RunnerTests` runner (ios/RunnerTests/RunnerTests.m)
// to take screenshots at all; `flutter test` alone cannot on iOS. macOS
// runs this same file directly via `flutter test -d macos`.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:app/main.dart' as app;
import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';

/// The seeded note (see `app/fastlane/lib/screenshot_seed.rb`) opened for
/// the "Note editor" screenshot — chosen for having both headings and a
/// blockquote, so the screenshot shows off rich Markdown rendering.
const _noteEditorTitle = 'Reading notes: Deep Work';

/// Matches [_noteEditorTitle] plus its own database row note, giving the
/// search screenshot a couple of real, on-topic results.
const _searchQuery = 'Deep Work';

/// The seeded sample database (see `screenshot_seed.rb`) opened for the
/// "Database view" screenshot.
const _databaseTitle = 'Reading list';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture App Store screenshots', (tester) async {
    await _configureFromEnvironment();

    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _screenshot(binding, tester, '01_notes_list');

    await tester.tap(find.text(_noteEditorTitle));
    await tester.pumpAndSettle();
    await _screenshot(binding, tester, '02_note_editor');

    await tester.tap(find.byKey(const Key('note.close')));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byKey(const Key('search.input')), _searchQuery);
    await tester.pumpAndSettle();
    await _screenshot(binding, tester, '03_search');

    final searchClose = find.byKey(const Key('search.close'));
    if (searchClose.evaluate().isNotEmpty) {
      await tester.tap(searchClose);
      await tester.pumpAndSettle();
    }

    await _openDatabase(tester, _databaseTitle);
    await _screenshot(binding, tester, '04_database_view');
  });
}

/// Points the app at the ephemeral screenshot server before `app.main()`
/// ever reads config, the same way a real device would after completing
/// setup — passed in via `--dart-define` by the fastlane lane, never
/// hardcoded, so this test can't accidentally target a real server.
Future<void> _configureFromEnvironment() async {
  const baseUrl = String.fromEnvironment('SCREENSHOT_SERVER_URL');
  const apiKey = String.fromEnvironment('SCREENSHOT_API_KEY');
  assert(
    baseUrl.isNotEmpty && apiKey.isNotEmpty,
    'SCREENSHOT_SERVER_URL and SCREENSHOT_API_KEY must be passed via '
    '--dart-define; see app/fastlane/Fastfile\'s capture_screenshots lane.',
  );

  final ConfigStore store = SecureConfigStore(
    storage: const FlutterSecureStorage(),
  );
  await store.write(
    const AppConfig(baseUrl: baseUrl, apiKey: apiKey, actor: 'Screenshots'),
  );
}

Future<void> _screenshot(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await binding.convertFlutterSurfaceToImage();
  await tester.pumpAndSettle();
  await binding.takeScreenshot(name);
}

/// Narrow (phone) layouts drive search from the bottom nav; wide
/// (tablet/desktop) layouts have no bottom nav and use a toolbar icon
/// instead — see `notes_list_screen.dart`'s `isWide` branching.
Future<void> _openSearch(WidgetTester tester) async {
  final narrow = find.byKey(const Key('notes.bottomNav.search'));
  await tester.tap(
    narrow.evaluate().isNotEmpty
        ? narrow
        : find.byKey(const Key('shell.search')),
  );
  await tester.pumpAndSettle();
}

/// Wide layouts show the folder/database sidebar inline; narrow layouts
/// keep it in a drawer opened from the bottom nav's "Folders" destination.
Future<void> _openDatabase(WidgetTester tester, String title) async {
  final wideSidebar = find.byKey(const Key('notes.sidebar.wide'));
  if (wideSidebar.evaluate().isEmpty) {
    await tester.tap(find.byKey(const Key('notes.bottomNav.folders')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(title).last);
  await tester.pumpAndSettle();
}
