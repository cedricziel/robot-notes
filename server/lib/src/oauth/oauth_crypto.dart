import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Lowercase hex SHA-256 digest of [raw].
///
/// This is the on-disk form of every OAuth secret: the file stem for
/// authorization codes and tokens, and the stored form of client secrets.
/// The raw value SHALL NOT be written to disk or logged anywhere.
String hashSecret(String raw) => sha256.convert(utf8.encode(raw)).toString();

/// Generates a URL-safe random token from [byteLength] bytes drawn from
/// [random], base64url-encoded without padding. Mirrors the token shape
/// `InviteStore` already uses for invite tokens.
String generateRandomToken(Random random, int byteLength) {
  final bytes = List<int>.generate(byteLength, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
