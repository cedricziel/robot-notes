import 'package:server/src/config.dart';

/// Process-wide handle on the resolved [Config].
///
/// `server/main.dart` resolves the configuration once via [Config.loadOrExit]
/// and calls [setConfig] before handing control to `dart_frog serve`. Route
/// middleware (`routes/_middleware.dart`) and any handler that needs config
/// reads it back via the [config] getter.
///
/// Keeping the holder in `lib/src/` (rather than wiring it through
/// `provider<Config>` only) lets the middleware constructor see the config
/// at registration time, which is necessary because the bearer-auth
/// middleware takes the configured key as a build-time argument.
Config? _config;

/// Installs the runtime [Config]. Idempotent only when called with the same
/// instance; calling twice with different configs is a wiring bug and
/// throws [StateError].
void setConfig(Config config) {
  final existing = _config;
  if (existing != null && !identical(existing, config)) {
    throw StateError(
      'setConfig called twice with different Config instances. '
      'Resolve configuration once in server/main.dart.',
    );
  }
  _config = config;
}

/// Returns the [Config] previously installed via [setConfig].
///
/// Throws [StateError] if read before [setConfig] runs — that indicates a
/// wiring bug (route middleware fired before the entrypoint resolved
/// config) and should fail loudly rather than serve traffic with defaults.
Config get config {
  final c = _config;
  if (c == null) {
    throw StateError(
      'Config was read before setConfig was called. '
      'Ensure server/main.dart calls setConfig(config) before serve().',
    );
  }
  return c;
}

/// Test-only hook to clear the holder between cases. Not exported from the
/// package barrel.
void debugResetConfig() {
  _config = null;
}
