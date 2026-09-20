import 'package:app/src/lock/biometric_authenticator.dart';

class FakeBiometricAuthenticator implements BiometricAuthenticator {
  FakeBiometricAuthenticator({
    this.capability = const LockCapability(
      supported: true,
      kind: BiometricKind.face,
    ),
    this.result = true,
  });

  LockCapability capability;
  bool result;
  int authenticateCalls = 0;
  String? lastReason;

  /// When set, [authenticate] waits on it, so tests can act mid-prompt.
  Future<void>? gate;

  @override
  Future<LockCapability> checkCapability() async => capability;

  @override
  Future<bool> authenticate(String reason) async {
    authenticateCalls++;
    lastReason = reason;
    await gate;
    return result;
  }
}
