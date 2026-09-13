import 'package:app/src/otel/device_resource_attributes.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deviceResourceAttributes', () {
    test('maps IosDeviceInfo to OTel device/os attributes', () async {
      final info = IosDeviceInfo.fromMap({
        'name': 'iPhone',
        'systemName': 'iOS',
        'systemVersion': '18.1',
        'model': 'iPhone',
        'modelName': 'iPhone 15 Pro',
        'localizedModel': 'iPhone',
        'freeDiskSize': 0,
        'totalDiskSize': 0,
        'isPhysicalDevice': true,
        'physicalRamSize': 0,
        'availableRamSize': 0,
        'isiOSAppOnMac': false,
        'isiOSAppOnVision': false,
        'utsname': {
          'sysname': 'Darwin',
          'nodename': 'iphone',
          'release': '23.0.0',
          'version': 'x',
          'machine': 'iPhone16,1',
        },
      });

      final attributes = await deviceResourceAttributes(
        deviceInfo: () async => info,
      );

      expect(attributes['device.model.identifier'], 'iPhone16,1');
      expect(attributes['device.model.name'], 'iPhone 15 Pro');
      expect(attributes['device.manufacturer'], 'Apple');
      expect(attributes['os.name'], 'iOS');
      expect(attributes['os.version'], '18.1');
      expect(attributes.containsKey('device.id'), isFalse);
    });

    test('maps MacOsDeviceInfo to OTel device/os attributes', () async {
      final info = MacOsDeviceInfo.fromMap({
        'computerName': 'cedric-mac',
        'hostName': 'cedric-mac.local',
        'arch': 'arm64',
        'model': 'Mac16,2',
        'modelName': 'iMac (24-inch, 2024)',
        'kernelVersion': 'Darwin Kernel Version 24.0.0',
        'osRelease': '24.0.0',
        'majorVersion': 15,
        'minorVersion': 1,
        'patchVersion': 0,
        'activeCPUs': 8,
        'memorySize': 0,
        'cpuFrequency': 0,
        'systemGUID': null,
      });

      final attributes = await deviceResourceAttributes(
        deviceInfo: () async => info,
      );

      expect(attributes['device.model.identifier'], 'Mac16,2');
      expect(attributes['device.model.name'], 'iMac (24-inch, 2024)');
      expect(attributes['device.manufacturer'], 'Apple');
      expect(attributes['os.name'], 'macOS');
      expect(attributes['os.version'], '15.1.0');
    });

    test('returns an empty map for an unrecognized platform', () async {
      final attributes = await deviceResourceAttributes(
        deviceInfo: () async => WebBrowserInfo.fromMap({}),
      );

      expect(attributes, isEmpty);
    });

    test('returns an empty map rather than throwing when device info lookup '
        'fails', () async {
      final attributes = await deviceResourceAttributes(
        deviceInfo: () async => throw Exception('platform channel down'),
      );

      expect(attributes, isEmpty);
    });

    test(
      'memoizes the default (non-injected) lookup for the process lifetime',
      () {
        final first = deviceResourceAttributes();
        final second = deviceResourceAttributes();

        expect(identical(first, second), isTrue);
      },
    );
  });
}
