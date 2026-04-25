import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:logging/logging.dart';

import 'package:server/src/app_deps.dart';
import 'package:server/src/app_deps_holder.dart';
import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart';
import 'package:shared/shared.dart';

/// Custom Dart Frog entrypoint hook.
///
/// Dart Frog calls this function with the framework-resolved [handler],
/// listen [ip], and the port from the `PORT` env var. We override the port
/// with what [Config] resolves so `ROBOT_NOTES_PORT` wins consistently.
///
/// Configuration flows exclusively through the `ROBOT_NOTES_*` environment
/// variables. The dart_frog generated `main()` does not forward user CLI
/// args, and `Platform.executableArguments` is reserved for VM-level flags
/// (e.g. `--resolved_executable_name`), not user input. Tests cover the
/// CLI-flag path directly via [Config.fromArgs].
Future<HttpServer> run(
  Handler handler,
  InternetAddress ip,
  int port,
) async {
  _installLoggerSink();

  final config = Config.loadOrExit(
    const <String>[],
    env: Platform.environment,
    exit: exit,
    printErr: stderr.writeln,
  );
  setConfig(config);

  final effectivePort = _portFromEnvOverride(config.port, port);
  _logResolvedConfig(config, effectivePort);

  final deps = await AppDeps.bootstrap(config);
  setAppDeps(deps);

  return serve(handler, ip, effectivePort);
}

int _portFromEnvOverride(int configured, int frameworkPort) {
  // If the user set ROBOT_NOTES_PORT or --port, honor it. Otherwise fall back
  // to whatever the framework resolved (the `PORT` env var, default 8080).
  return configured == Config.defaultPort ? frameworkPort : configured;
}

void _installLoggerSink() {
  // package:logging records are otherwise dropped on the floor — the root
  // logger has no listeners until something hooks `onRecord`. Wire one to
  // stderr so AppDeps.bootstrap and friends actually print.
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    stderr.writeln(
      '${r.time.toIso8601String()} ${r.level.name.padRight(7)} '
      '${r.loggerName}: ${r.message}',
    );
    if (r.error != null) stderr.writeln('  error: ${r.error}');
    if (r.stackTrace != null) stderr.writeln(r.stackTrace);
  });
}

void _logResolvedConfig(Config config, int effectivePort) {
  // Operator-facing startup banner. Every value here is non-secret except
  // the API key, which is logged only as a length so the operator can
  // confirm it was picked up without leaking the secret to logs/journals.
  Logger('boot')
    ..info('robot-notes server $robotNotesVersion')
    ..info('  port:     $effectivePort')
    ..info('  data dir: ${config.dataDir}')
    ..info('  web dir:  ${config.webDir ?? '(unset — API-only mode)'}')
    ..info('  lock ttl: ${config.lockTtlSeconds}s')
    ..info('  api key:  configured (length=${config.apiKey.length})');
}
