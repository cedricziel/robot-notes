import 'package:local_auth/local_auth.dart';

/// Which biometric the device offers, for wording only ("Face ID" vs
/// "Touch ID"). [other] covers strong/weak-class biometrics that don't say
/// which sensor they are, and devices that only have a passcode.
enum BiometricKind { face, fingerprint, other }

/// What the device can do for an app lock.
class LockCapability {
  const LockCapability({required this.supported, required this.kind});

  static const unsupported = LockCapability(
    supported: false,
    kind: BiometricKind.other,
  );

  /// Whether the device can authenticate the user at all — biometrics, or
  /// failing that a device passcode.
  final bool supported;
  final BiometricKind kind;
}

/// The device-owner check behind the app lock, kept behind an interface so
/// widget tests never touch a platform channel.
abstract class BiometricAuthenticator {
  Future<LockCapability> checkCapability();

  /// Shows the system prompt. `false` on cancel, failure, or any platform
  /// error — callers treat all of those as "not unlocked".
  Future<bool> authenticate(String reason);
}

/// Production [BiometricAuthenticator] on top of `local_auth`. Passcode
/// fallback stays on (the plugin default) so a wet finger or a masked face
/// doesn't lock the user out of their own notes.
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<LockCapability> checkCapability() async {
    try {
      if (!await _auth.isDeviceSupported()) return LockCapability.unsupported;
      final types = await _auth.getAvailableBiometrics();
      final kind = types.contains(BiometricType.face)
          ? BiometricKind.face
          : types.contains(BiometricType.fingerprint)
          ? BiometricKind.fingerprint
          : BiometricKind.other;
      return LockCapability(supported: true, kind: kind);
    } catch (_) {
      // Web/Linux have no plugin implementation; treat that as "no lock".
      return LockCapability.unsupported;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
