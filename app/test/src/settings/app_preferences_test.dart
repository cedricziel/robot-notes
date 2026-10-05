import 'package:app/src/settings/app_preferences.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The storage interface is provided by shared_preferences for platform fakes.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failure in ['initialization', 'write', 'rejected write']) {
    test('storage $failure preserves preferences and notifications', () async {
      final originalStore = SharedPreferencesStorePlatform.instance;
      final originalDebugPrint = debugPrint;
      final logs = <String?>[];
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _FailingPreferencesStore(
        failure,
      );
      debugPrint = (message, {wrapWidth}) => logs.add(message);
      final preferences = AppPreferences();
      addTearDown(() {
        preferences.dispose();
        debugPrint = originalDebugPrint;
        SharedPreferencesStorePlatform.instance = originalStore;
        SharedPreferences.resetStatic();
      });
      var notifications = 0;
      preferences.addListener(() => notifications++);

      await expectLater(preferences.setThemeMode(ThemeMode.dark), completes);
      await expectLater(preferences.setSidebarWidth(900), completes);

      expect(preferences.themeMode, ThemeMode.dark);
      expect(preferences.sidebarWidth, 420);
      expect(notifications, 2);
      expect(logs, hasLength(2));
      expect(logs[0], contains('Could not save device preferences'));
      expect(logs[1], contains('Could not save device preferences'));
    });
  }

  test('appearance and pane width survive a new controller', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AppPreferences();
    await first.setThemeMode(ThemeMode.dark);
    await first.setSidebarWidth(350);
    final restored = AppPreferences();
    await restored.load();
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.sidebarWidth, 350);
    first.dispose();
    restored.dispose();
  });

  test('a pending load is safe after disposal', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = AppPreferences();
    final loading = preferences.load();
    preferences.dispose();
    await loading;
  });

  test('invalid stored values fall back safely', () async {
    SharedPreferences.setMockInitialValues({
      'appearance.theme': 'invalid',
      'workspace.sidebarWidth': 900.0,
    });
    final preferences = AppPreferences();
    await preferences.load();
    expect(preferences.themeMode, ThemeMode.system);
    expect(preferences.sidebarWidth, 420);
    preferences.dispose();
  });
}

class _FailingPreferencesStore extends InMemorySharedPreferencesStore {
  _FailingPreferencesStore(this.failure) : super.empty();

  final String failure;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failure == 'initialization') throw StateError('storage unavailable');
    return super.getAll();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failure == 'write') throw StateError('write failed');
    return false;
  }
}
