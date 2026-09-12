import 'dart:async';

import 'package:app/src/otel/logging_bridge.dart';
import 'package:app/src/otel/otel_build_config.dart';
import 'package:flutter_otel/flutter_otel.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart' as logging;
import 'package:shared/shared.dart';

/// Initializes the app's [OTelSdk]. Reads OTLP endpoint/headers from
/// [buildConfig] (defaulting to the `--dart-define`d build configuration).
/// When no endpoint is configured, the SDK wires up no-op exporters, so
/// logging/tracing calls are always safe to leave in place.
Future<OTelSdk> bootstrapOtel({
  OtelBuildConfig? buildConfig,
  http.Client? httpClient,
}) {
  final config = buildConfig ?? OtelBuildConfig.fromEnvironment();
  return OTelSdk.initialize(
    OTelSdkConfig(
      resource: OTelResource(
        serviceName: 'robot-notes-app',
        serviceVersion: robotNotesVersion,
      ),
      enabled: config.endpoint != null,
      otlpEndpoint: config.endpoint,
      otlpHeaders: config.headers,
      httpClient: httpClient,
    ),
  );
}

StreamSubscription<logging.LogRecord>? _bridgeSubscription;

/// Bootstraps (or re-bootstraps) OTel for the running app and wires the
/// logging bridge. Safe to call more than once: a Flutter hot restart
/// re-executes `main()` in the same isolate, so without resetting the
/// previous [OTelSdk] instance and cancelling its bridge subscription
/// first, each restart would leak a live batch-export timer, an owned
/// `http.Client`, and a stale `Logger.root` listener. Returns the active
/// SDK.
Future<OTelSdk> initOtel({
  OtelBuildConfig? buildConfig,
  http.Client? httpClient,
}) async {
  await _bridgeSubscription?.cancel();
  await OTelSdk.reset();
  final sdk = await bootstrapOtel(
    buildConfig: buildConfig,
    httpClient: httpClient,
  );
  _bridgeSubscription = installOtelLoggingBridge(sdk.loggerProvider);
  return sdk;
}
