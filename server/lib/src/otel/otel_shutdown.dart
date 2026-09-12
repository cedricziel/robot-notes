import 'dart:async';
import 'dart:io';

import 'package:flutter_otel_api/flutter_otel_api.dart';

/// Flushes and shuts down [otelLoggerProvider], then calls [closeServer]
/// (even if the otel shutdown throws — the server always releases its
/// port). Exposed separately from [installShutdownSignalHandlers] so the
/// actual shutdown sequence is unit-testable without a real [HttpServer]
/// or process signal.
Future<void> shutdownServer({
  required LoggerProvider otelLoggerProvider,
  required Future<void> Function() closeServer,
}) async {
  try {
    await otelLoggerProvider.shutdown();
  } finally {
    await closeServer();
  }
}

/// Registers SIGINT/SIGTERM handlers (SIGTERM isn't supported on Windows)
/// that run [shutdownServer] and then exit the process. Without this,
/// in-flight OTel log exports are dropped and the exporter's owned
/// [HttpClient] is never closed when the process is killed — e.g. on a
/// container redeploy, which sends SIGTERM.
void installShutdownSignalHandlers({
  required LoggerProvider otelLoggerProvider,
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
        otelLoggerProvider: otelLoggerProvider,
        closeServer: closeServer,
      );
      exit(0);
    });
  }
}
