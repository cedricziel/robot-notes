import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import 'package:server/src/app_deps.dart';
import 'package:server/src/app_deps_holder.dart';
import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart';

/// Custom Dart Frog entrypoint hook.
///
/// Dart Frog calls this function with the framework-resolved [handler],
/// listen [ip], and the port from the `PORT` env var. We override the port
/// with what [Config] resolves so `ROBOT_NOTES_PORT` and `--port` win
/// consistently.
///
/// The CLI flags documented in the `auth` and `lock-management` specs are
/// honored when this binary is invoked through a wrapper that forwards
/// `Platform.executableArguments`; in production (e.g. `dart_frog build`
/// + a Docker image) configuration flows through the `ROBOT_NOTES_*`
/// environment variables.
Future<HttpServer> run(
  Handler handler,
  InternetAddress ip,
  int port,
) async {
  final config = Config.loadOrExit(
    Platform.executableArguments,
    env: Platform.environment,
    exit: exit,
    printErr: stderr.writeln,
  );
  setConfig(config);

  final deps = await AppDeps.bootstrap(config);
  setAppDeps(deps);

  final effectivePort = _portFromEnvOverride(config.port, port);
  return serve(handler, ip, effectivePort);
}

int _portFromEnvOverride(int configured, int frameworkPort) {
  // If the user set ROBOT_NOTES_PORT or --port, honor it. Otherwise fall back
  // to whatever the framework resolved (the `PORT` env var, default 8080).
  return configured == Config.defaultPort ? frameworkPort : configured;
}
