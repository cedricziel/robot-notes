import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:server/src/constant_time.dart';

/// RFC 7636 §4.1 code-verifier charset and length: 43 to 128 characters
/// from the unreserved set `[A-Za-z0-9-._~]`.
final RegExp _kValidVerifier = RegExp(r'^[A-Za-z0-9._~-]{43,128}$');

/// Computes the RFC 7636 S256 code challenge for [verifier]: base64url
/// (no padding) of the SHA-256 digest of the verifier's UTF-8 bytes.
///
/// Hashes UTF-8 rather than ASCII bytes so a non-ASCII (and therefore
/// already outside the RFC 7636 charset) verifier still yields a value
/// instead of throwing; [pkceVerify] is what actually enforces the
/// charset and length.
String pkceS256Challenge(String verifier) {
  final digest = sha256.convert(utf8.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Verifies that [verifier] reproduces the stored [challenge], comparing in
/// constant time so response timing cannot leak how many characters
/// matched. Never throws: returns `false` for a [verifier] outside the RFC
/// 7636 code-verifier charset and length (`[A-Za-z0-9._~-]{43,128}`).
bool pkceVerify({required String challenge, required String verifier}) {
  if (!_kValidVerifier.hasMatch(verifier)) return false;
  return constantTimeEquals(challenge, pkceS256Challenge(verifier));
}
