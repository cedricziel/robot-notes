import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local appearance and workspace preferences, independent of a vault.
class AppPreferences extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  double sidebarWidth = 260;
  bool _disposed = false;
  int _revision = 0;

  Future<void> load() async {
    final revision = _revision;
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('Could not load device preferences: $error');
      return;
    }
    if (_disposed || revision != _revision) return;
    final mode = prefs.getString('appearance.theme');
    themeMode = ThemeMode.values.firstWhere(
      (value) => value.name == mode,
      orElse: () => ThemeMode.system,
    );
    sidebarWidth = (prefs.getDouble('workspace.sidebarWidth') ?? 260).clamp(
      200,
      420,
    );
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_disposed) return;
    _revision++;
    themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('appearance.theme', mode.name)) {
        debugPrint('Could not save device preferences: appearance.theme');
      }
    } catch (error) {
      debugPrint('Could not save device preferences: $error');
    }
  }

  Future<void> setSidebarWidth(double width) async {
    if (_disposed) return;
    _revision++;
    sidebarWidth = width.clamp(200, 420);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setDouble('workspace.sidebarWidth', sidebarWidth)) {
        debugPrint('Could not save device preferences: workspace.sidebarWidth');
      }
    } catch (error) {
      debugPrint('Could not save device preferences: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppPreferencesScope extends InheritedNotifier<AppPreferences> {
  const AppPreferencesScope({
    required AppPreferences preferences,
    required super.child,
    super.key,
  }) : super(notifier: preferences);

  static AppPreferences? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()
      ?.notifier;
}
