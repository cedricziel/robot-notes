import 'package:app/src/lock/biometric_authenticator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

class _MockLocalAuth extends Mock implements LocalAuthentication {}

void main() {
  late _MockLocalAuth local;
  late LocalAuthBiometricAuthenticator authenticator;

  setUp(() {
    local = _MockLocalAuth();
    authenticator = LocalAuthBiometricAuthenticator(local);
  });

  group('checkCapability', () {
    test('reports the biometric kind on a supported device', () async {
      when(() => local.isDeviceSupported()).thenAnswer((_) async => true);
      when(
        () => local.getAvailableBiometrics(),
      ).thenAnswer((_) async => [BiometricType.face]);

      final cap = await authenticator.checkCapability();
      expect(cap.supported, isTrue);
      expect(cap.kind, BiometricKind.face);
    });

    test('a device that cannot authenticate is unsupported', () async {
      when(() => local.isDeviceSupported()).thenAnswer((_) async => false);
      expect((await authenticator.checkCapability()).supported, isFalse);
    });

    test('a missing plugin (web, Linux) is unsupported', () async {
      when(() => local.isDeviceSupported()).thenThrow(MissingPluginException());
      expect((await authenticator.checkCapability()).supported, isFalse);
    });

    test('any other error is not mistaken for "unsupported"', () async {
      when(
        () => local.isDeviceSupported(),
      ).thenThrow(PlatformException(code: 'boom'));
      expect(
        authenticator.checkCapability(),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
