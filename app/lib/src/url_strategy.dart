// Sets the path (non-hash) URL strategy on web, no-op elsewhere.
//
// `package:flutter_web_plugins` pulls in `dart:ui_web`, which does not
// exist on the VM target `flutter test` runs against, so the web
// implementation is only reachable through this conditional export —
// importing it directly from `main.dart` would break every widget test.
export 'url_strategy_stub.dart'
    if (dart.library.js_interop) 'url_strategy_web.dart';
