import 'package:app/src/settings/app_preferences.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
