/// No-op window chrome for platforms without `dart:io` (Web).
///
/// Unified-title-bar support only targets macOS; this stub keeps
/// `main.dart` and `mac_window_chrome.dart` platform-agnostic without
/// pulling `dart:io`-only packages into the Web build.
class WindowChromeController {
  Future<void> init() async {}
}

Future<void> startWindowDrag() async {}

Future<void> toggleWindowZoom() async {}
