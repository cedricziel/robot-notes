import 'package:device_info_plus/device_info_plus.dart';

/// Best-effort OTel `device.*`/`os.*` resource attributes for the running
/// device, sourced from [DeviceInfoPlugin.deviceInfo] by default (which
/// picks the right per-platform getter at runtime). Deliberately omits
/// `device.id`: no persistent per-device identifier is collected.
///
/// [deviceInfo] is injectable so tests can supply an [IosDeviceInfo] or
/// [MacOsDeviceInfo] directly — [DeviceInfoPlugin.deviceInfo] itself
/// dispatches on the actual host platform, which is always the test
/// runner's OS, never the platform under test.
///
/// Never throws — an unsupported platform (web, desktop other than macOS,
/// or a missing platform channel) resolves to an empty map, since telemetry
/// enrichment must never be able to break the app.
///
/// The default (non-injected) lookup is memoized for the life of the
/// process: device model/OS version can't change between the app's
/// `bootstrapOtel` calls (a hot restart, a reconnect, a server change), so
/// repeating the platform-channel round trip on each one would be pure
/// waste.
Future<Map<String, Object?>> deviceResourceAttributes({
  Future<BaseDeviceInfo> Function()? deviceInfo,
}) {
  if (deviceInfo == null) {
    return _defaultAttributes ??= _resolve(() => DeviceInfoPlugin().deviceInfo);
  }
  return _resolve(deviceInfo);
}

/// Memoized result of the default (non-injected) lookup — see
/// [deviceResourceAttributes].
Future<Map<String, Object?>>? _defaultAttributes;

Future<Map<String, Object?>> _resolve(
  Future<BaseDeviceInfo> Function() deviceInfo,
) async {
  try {
    final info = await deviceInfo();
    return switch (info) {
      IosDeviceInfo(
        :final utsname,
        :final modelName,
        :final systemName,
        :final systemVersion,
      ) =>
        {
          'device.model.identifier': utsname.machine,
          'device.model.name': modelName,
          'device.manufacturer': 'Apple',
          'os.name': systemName,
          'os.version': systemVersion,
        },
      MacOsDeviceInfo(
        :final model,
        :final modelName,
        :final majorVersion,
        :final minorVersion,
        :final patchVersion,
      ) =>
        {
          'device.model.identifier': model,
          'device.model.name': modelName,
          'device.manufacturer': 'Apple',
          'os.name': 'macOS',
          'os.version': '$majorVersion.$minorVersion.$patchVersion',
        },
      _ => const <String, Object?>{},
    };
  } catch (_) {
    return const <String, Object?>{};
  }
}
