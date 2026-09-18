import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the note view's property panel (task 7.1) is collapsed,
/// per device — the spec's "collapsible with collapsed state remembered
/// per device" — independent of which note is open, matching the editor's
/// existing preview-pane toggle in spirit but persisted across sessions.
abstract class PropertyPanelPrefs {
  Future<bool> readCollapsed();
  Future<void> writeCollapsed(bool collapsed);
}

/// Production [PropertyPanelPrefs] backed by `shared_preferences` (local
/// device storage — not synced, not sent to the server). Every call is
/// wrapped so a platform without a working prefs backend (or one blocked by
/// the sandbox) degrades to "not collapsed" rather than throwing.
class SharedPreferencesPropertyPanelPrefs implements PropertyPanelPrefs {
  const SharedPreferencesPropertyPanelPrefs();

  static const _key = 'robot_notes.note_property_panel.collapsed';

  @override
  Future<bool> readCollapsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> writeCollapsed(bool collapsed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, collapsed);
    } catch (_) {
      // Best-effort: nothing actionable the panel can do about a storage
      // failure beyond keeping the in-memory collapsed state for this
      // session.
    }
  }
}

/// In-memory [PropertyPanelPrefs] for tests.
class InMemoryPropertyPanelPrefs implements PropertyPanelPrefs {
  InMemoryPropertyPanelPrefs({bool collapsed = false}) : _collapsed = collapsed;

  bool _collapsed;

  @override
  Future<bool> readCollapsed() async => _collapsed;

  @override
  Future<void> writeCollapsed(bool collapsed) async => _collapsed = collapsed;
}
