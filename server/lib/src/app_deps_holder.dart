import 'package:server/src/app_deps.dart';

/// Process-wide handle on the resolved [AppDeps].
///
/// Mirrors `config_holder.dart`: `server/main.dart` builds the deps once
/// from the resolved Config and calls [setAppDeps] before handing control
/// to `dart_frog serve`. Route middleware (`routes/_middleware.dart`) reads
/// it back via the [appDeps] getter.
AppDeps? _deps;

/// Installs the runtime [AppDeps]. Idempotent only when called with the
/// same instance; calling twice with different deps is a wiring bug and
/// throws [StateError].
void setAppDeps(AppDeps deps) {
  final existing = _deps;
  if (existing != null && !identical(existing, deps)) {
    throw StateError(
      'setAppDeps called twice with different AppDeps instances. '
      'Resolve dependencies once in server/main.dart.',
    );
  }
  _deps = deps;
}

/// Returns the [AppDeps] previously installed via [setAppDeps].
///
/// Throws [StateError] if read before [setAppDeps] runs.
AppDeps get appDeps {
  final d = _deps;
  if (d == null) {
    throw StateError(
      'AppDeps was read before setAppDeps was called. '
      'Ensure server/main.dart calls setAppDeps(deps) before serve().',
    );
  }
  return d;
}

/// Test-only hook to clear the holder between cases. Not exported from the
/// package barrel.
void debugResetAppDeps() {
  _deps = null;
}
