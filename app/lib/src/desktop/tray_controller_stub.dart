/// No-op tray controller for platforms without `dart:io` (Web).
///
/// Tray/window-manager support only targets macOS; this stub keeps
/// `main.dart` platform-agnostic without pulling `dart:io`-only packages
/// into the Web build.
class TrayController {
  Future<void> init() async {}

  Future<void> hideWindow() async {}
}
