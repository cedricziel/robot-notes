// Installs a raw browser-level Cmd+S/Ctrl+S handler on web, no-op elsewhere.
//
// `package:web` pulls in `dart:js_interop`, which doesn't exist on the VM
// target `flutter test` runs against, so the web implementation is only
// reachable through this conditional export — importing it directly from
// `note_screen.dart` would break every widget test.
export 'save_shortcut_stub.dart'
    if (dart.library.js_interop) 'save_shortcut_web.dart';
