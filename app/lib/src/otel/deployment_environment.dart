import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_otel_native/flutter_otel_native.dart';

/// The `deployment.environment.name` OTel resource attribute for this app
/// build: `"development"` for a debug build, otherwise whichever channel
/// [distributionEnvironment] (defaulting to
/// [NativeTelemetryBridge.distributionEnvironment], a native check of the
/// app's StoreKit receipt) reports — `"testflight"` or `"production"`.
///
/// [distributionEnvironment] reports `"unknown"` whenever it can't give a
/// definitive answer: no native plugin for this platform (Android/Web/
/// desktop), or an indeterminate receipt state on iOS/macOS. For a
/// *release* build, `"unknown"` is remapped to `"production"` here rather
/// than propagated — every one of those platforms/states is still a real
/// production release, not a dev build.
Future<String> deploymentEnvironmentName({
  bool releaseMode = kReleaseMode,
  Future<String> Function() distributionEnvironment =
      _defaultDistributionEnvironment,
}) async {
  if (!releaseMode) return 'development';
  final env = await distributionEnvironment();
  return env == 'unknown' ? 'production' : env;
}

Future<String> _defaultDistributionEnvironment() =>
    NativeTelemetryBridge().distributionEnvironment();
