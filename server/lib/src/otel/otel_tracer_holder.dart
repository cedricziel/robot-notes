import 'package:flutter_otel_api/flutter_otel_api.dart';

/// Process-wide handle on the resolved [TracerProvider].
///
/// Mirrors `config_holder.dart`: `server/main.dart` builds the provider once
/// via `createOtelTracerProvider` and calls [setOtelTracerProvider] before
/// handing control to `dart_frog serve`. Route middleware and domain code
/// that need to start spans read it back via the [otelTracerProvider]
/// getter, since dart_frog's `provider<T>()` mechanism isn't available to
/// code that runs outside the request-handling chain (e.g. constructing
/// other middleware at registration time).
TracerProvider? _tracerProvider;

/// Installs the runtime [TracerProvider]. Idempotent only when called with
/// the same instance; calling twice with different providers is a wiring
/// bug and throws [StateError].
void setOtelTracerProvider(TracerProvider provider) {
  final existing = _tracerProvider;
  if (existing != null && !identical(existing, provider)) {
    throw StateError(
      'setOtelTracerProvider called twice with different TracerProvider '
      'instances. Resolve the tracer provider once in server/main.dart.',
    );
  }
  _tracerProvider = provider;
}

/// Returns the [TracerProvider] previously installed by
/// [setOtelTracerProvider].
///
/// Throws [StateError] if read before [setOtelTracerProvider] runs — that
/// indicates a wiring bug (code fired before the entrypoint resolved the
/// provider) and should fail loudly rather than silently trace nothing.
TracerProvider get otelTracerProvider {
  final provider = _tracerProvider;
  if (provider == null) {
    throw StateError(
      'TracerProvider was read before setOtelTracerProvider was called. '
      'Ensure server/main.dart calls setOtelTracerProvider(provider) '
      'before serve().',
    );
  }
  return provider;
}

/// Test-only hook to clear the holder between cases. Not exported from the
/// package barrel.
void debugResetOtelTracerProvider() {
  _tracerProvider = null;
}
