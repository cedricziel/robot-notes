/// Conditional-export switchboard for `LoopbackRedirectServer`.
library;

// The real `dart:io`-backed `LoopbackRedirectServer` on every platform
// that has `dart:io` (desktop, mobile); a stub that throws
// `UnsupportedError` on web (`dart:io` does not exist there at all —
// this is a hard compile error, not just a runtime one, if a web build
// ever imported the `dart:io` file directly).
export 'loopback_redirect_result.dart';
export 'loopback_redirect_stub.dart'
    if (dart.library.io) 'loopback_redirect_io.dart';
