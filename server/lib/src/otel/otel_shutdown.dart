import 'dart:async';
import 'dart:io';

/// Runs every closure in [otelShutdowns] (e.g. `provider.shutdown` for each
/// otel signal's provider — logs, traces, and eventually metrics), then
/// calls [closeServer] (even if a shutdown throws — the server always
/// releases its port). Every closure gets a shutdown attempt even if
/// another throws, since [Future.wait] defaults to `eagerError: false`.
///
/// Takes shutdown actions rather than the provider types directly so that
/// adding a new otel signal (e.g. a `MeterProvider` once metrics land)
/// doesn't require another named parameter here — just one more closure at
/// the call site in `server/main.dart`.
///
/// Exposed separately from [installShutdownSignalHandlers] so the actual
/// shutdown sequence is unit-testable without a real [HttpServer] or
/// process signal.
Future<void> shutdownServer({
  required List<Future<void> Function()> otelShutdowns,
  required Future<void> Function() closeServer,
}) async {
  try {
    await Future.wait([for (final shutdown in otelShutdowns) shutdown()]);
  } finally {
    await closeServer();
  }
}

/// Registers SIGINT/SIGTERM handlers (SIGTERM isn't supported on Windows)
/// that run [shutdownServer] and then exit the process. Without this,
/// in-flight OTel exports are dropped and the exporters' owned
/// [HttpClient]s are never closed when the process is killed — e.g. on a
/// container redeploy, which sends SIGTERM.
void installShutdownSignalHandlers({
  required List<Future<void> Function()> otelShutdowns,
  required Future<void> Function() closeServer,
  required void Function(int code) exit,
}) {
  final signals = [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  for (final signal in signals) {
    signal.watch().listen((_) async {
      await shutdownServer(
        otelShutdowns: otelShutdowns,
        closeServer: closeServer,
      );
      exit(0);
    });
  }
}
