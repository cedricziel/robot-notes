import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:server/src/constant_time.dart';

/// Computes the RFC 7636 S256 code challenge for [verifier]: base64url
/// (no padding) of the SHA-256 digest of the verifier's ASCII bytes.
String pkceS256Challenge(String verifier) {
  final digest = sha256.convert(ascii.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Verifies that [verifier] reproduces the stored [challenge], comparing in
/// constant time so response timing cannot leak how many characters
/// matched. Never throws: a [verifier] outside the RFC 7636 ASCII charset
/// simply fails to match.
bool pkceVerify({required String challenge, required String verifier}) {
  if (!_isAscii(verifier)) return false;
  return constantTimeEquals(challenge, pkceS256Challenge(verifier));
}

bool _isAscii(String s) => s.codeUnits.every((c) => c < 128);
