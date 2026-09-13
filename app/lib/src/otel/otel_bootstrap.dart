import 'dart:async';

import 'package:app/src/config/app_config.dart';
import 'package:app/src/otel/deployment_environment.dart';
import 'package:app/src/otel/device_resource_attributes.dart';
import 'package:app/src/otel/logging_bridge.dart';
import 'package:app/src/otel/otel_build_config.dart';
import 'package:app/src/otel/remote_otel_config.dart';
import 'package:flutter_otel/flutter_otel.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart' as logging;
import 'package:shared/shared.dart';

/// Initializes the app's [OTelSdk] from [buildConfig] (defaulting to
/// disabled — see [syncOtelWithConfig] for how the app resolves this at
/// runtime from the connected server). When no endpoint is configured, the
/// SDK wires up no-op exporters, so logging/tracing calls are always safe to
/// leave in place.
Future<OTelSdk> bootstrapOtel({
  OtelBuildConfig? buildConfig,
  http.Client? httpClient,
}) async {
  final config = buildConfig ?? const OtelBuildConfig();
  return OTelSdk.initialize(
    OTelSdkConfig(
      resource: OTelResource(
        serviceName: 'robot-notes-app',
        serviceVersion: robotNotesVersion,
        attributes: {
          'service.namespace': otelServiceNamespace,
          'deployment.environment.name': await deploymentEnvironmentName(),
          ...await deviceResourceAttributes(),
        },
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

/// Re-initializes OTel from whatever the currently connected server (per
/// [config]) reports at `/otel-config` — `null` (no config, e.g. pre-setup
/// or after a disconnect) re-initializes disabled. This is how the app and
/// web bundle enable telemetry at runtime: by asking their own server,
/// instead of a value baked in at build time.
Future<OTelSdk> syncOtelWithConfig(
  AppConfig? config, {
  http.Client? httpClient,
}) async {
  final buildConfig = config == null
      ? const OtelBuildConfig()
      : await fetchRemoteOtelConfig(config.baseUrl, httpClient: httpClient);
  return initOtel(buildConfig: buildConfig, httpClient: httpClient);
}
