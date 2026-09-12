import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart';
import 'package:server/src/oidc/jwks.dart';

/// Why [verifyIdToken] rejected a token.
enum IdTokenVerificationFailure {
  /// The token is not a well-formed three-segment compact JWS, or a
  /// required claim (`sub`, `exp`, `nonce`, `kid`) is missing or the
  /// wrong type.
  malformed,

  /// `alg` is `none`, or anything outside [isAllowedJwsAlgorithm].
  badAlgorithm,

  /// The header's `kid` does not match any key in the provider's JWKS,
  /// even after one refetch.
  unknownKey,

  /// The JWS signature does not verify against the named key.
  badSignature,

  /// `iss` does not equal the configured issuer.
  wrongIssuer,

  /// `aud` does not include the configured client id, or `aud` has more
  /// than one value and `azp` is absent or does not equal it.
  wrongAudience,

  /// `exp` is in the past.
  expired,

  /// `nonce` does not match the value bound to the pending login.
  nonceMismatch,
}

/// Thrown by [verifyIdToken] when a token is rejected for any reason.
@immutable
class IdTokenVerificationException implements Exception {
  /// Creates the exception for [failure], with a human-readable [message].
  const IdTokenVerificationException(this.failure, this.message);

  /// Which check failed.
  final IdTokenVerificationFailure failure;

  /// Detail suitable for a startup/debug log — never logged with token
  /// material.
  final String message;

  @override
  String toString() => 'IdTokenVerificationException($failure): $message';
}

/// The claims of a verified ID token this server acts on.
@immutable
class IdTokenClaims {
  /// Creates a claims record. [raw] holds every claim from the payload.
  const IdTokenClaims({
    required this.sub,
    required this.raw,
    this.name,
    this.email,
  });

  /// The subject identifier.
  final String sub;

  /// Display name, when present.
  final String? name;

  /// Email address, when present.
  final String? email;

  /// The full decoded JWT payload.
  final Map<String, dynamic> raw;
}

/// Verifies a compact-JWS ID [token]: signature (via [jwks]), `iss`
/// against [issuer], `aud` against [audience], `exp` against [now] (real
/// time by default), and `nonce` against [nonce].
///
/// Throws [IdTokenVerificationException] naming the specific failure on
/// any check failing. The algorithm allowlist is checked *before* any key
/// lookup or signature verification is attempted, so an `alg=none` token
/// never reaches the signature-verification code path.
Future<IdTokenClaims> verifyIdToken(
  String token, {
  required String issuer,
  required String audience,
  required String nonce,
  required JwksCache jwks,
  DateTime Function() now = DateTime.now,
}) async {
  final parts = token.split('.');
  if (parts.length != 3) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.malformed,
      'Token is not a three-segment compact JWS.',
    );
  }

  final header = _decodeJsonSegment(parts[0]);
  final alg = header?['alg'];
  if (alg is! String || !isAllowedJwsAlgorithm(alg)) {
    throw IdTokenVerificationException(
      IdTokenVerificationFailure.badAlgorithm,
      'Unsupported or missing alg: $alg',
    );
  }

  final kid = header?['kid'];
  if (kid is! String) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.malformed,
      'Token header is missing kid.',
    );
  }

  final jwk = await jwks.keyForId(kid);
  if (jwk == null) {
    throw IdTokenVerificationException(
      IdTokenVerificationFailure.unknownKey,
      'No key named "$kid" in the provider\'s JWKS.',
    );
  }

  final signingInput = utf8.encode('${parts[0]}.${parts[1]}');
  final Uint8List signatureBytes;
  try {
    signatureBytes = _base64UrlDecode(parts[2]);
  } on FormatException {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.malformed,
      'Signature segment is not valid base64url.',
    );
  }

  final verified = _verifySignature(
    alg,
    jwk,
    Uint8List.fromList(signingInput),
    signatureBytes,
  );
  if (!verified) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.badSignature,
      'Signature verification failed.',
    );
  }

  final payload = _decodeJsonSegment(parts[1]);
  if (payload == null) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.malformed,
      'Payload segment is not a JSON object.',
    );
  }

  final iss = payload['iss'];
  if (iss != issuer) {
    throw IdTokenVerificationException(
      IdTokenVerificationFailure.wrongIssuer,
      'Expected iss "$issuer", got "$iss".',
    );
  }

  final aud = payload['aud'];
  final audOk = aud == audience || (aud is List && aud.contains(audience));
  if (!audOk) {
    throw IdTokenVerificationException(
      IdTokenVerificationFailure.wrongAudience,
      'aud does not include "$audience".',
    );
  }
  // Per OpenID Connect Core 1.0 §3.1.3.7 (11): a multi-valued aud requires
  // azp naming this client, so a token also valid for another audience
  // can't be replayed here without that audience's cooperation.
  if (aud is List && aud.length > 1 && payload['azp'] != audience) {
    throw IdTokenVerificationException(
      IdTokenVerificationFailure.wrongAudience,
      'Multi-valued aud requires azp == "$audience".',
    );
  }

  final exp = payload['exp'];
  if (exp is! int) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.malformed,
      'Payload is missing a numeric exp.',
    );
  }
  final expiresAt = DateTime.fromMillisecondsSinceEpoch(
    exp * 1000,
    isUtc: true,
  );
  if (!expiresAt.isAfter(now().toUtc())) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.expired,
      'Token has expired.',
    );
  }

  final tokenNonce = payload['nonce'];
  if (tokenNonce != nonce) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.nonceMismatch,
      'nonce does not match the pending login.',
    );
  }

  final sub = payload['sub'];
  if (sub is! String) {
    throw const IdTokenVerificationException(
      IdTokenVerificationFailure.malformed,
      'Payload is missing sub.',
    );
  }

  return IdTokenClaims(
    sub: sub,
    name: payload['name'] as String?,
    email: payload['email'] as String?,
    raw: payload,
  );
}

Map<String, dynamic>? _decodeJsonSegment(String segment) {
  final Uint8List bytes;
  try {
    bytes = _base64UrlDecode(segment);
  } on FormatException {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}

Uint8List _base64UrlDecode(String segment) {
  final padded = switch (segment.length % 4) {
    2 => '$segment==',
    3 => '$segment=',
    _ => segment,
  };
  return base64Url.decode(padded);
}

bool _verifySignature(
  String alg,
  Jwk jwk,
  Uint8List signingInput,
  Uint8List signatureBytes,
) {
  return switch (alg) {
    'RS256' => _verifyRs256(jwk, signingInput, signatureBytes),
    'ES256' => _verifyEs256(jwk, signingInput, signatureBytes),
    _ => false,
  };
}

bool _verifyRs256(Jwk jwk, Uint8List signingInput, Uint8List signatureBytes) {
  if (jwk.kty != 'RSA') return false;
  final n = jwk.raw['n'];
  final e = jwk.raw['e'];
  if (n is! String || e is! String) return false;

  final publicKey = RSAPublicKey(
    _bytesToBigInt(_base64UrlDecode(n)),
    _bytesToBigInt(_base64UrlDecode(e)),
  );
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
  try {
    return signer.verifySignature(signingInput, RSASignature(signatureBytes));
  } on Object {
    return false;
  }
}

bool _verifyEs256(Jwk jwk, Uint8List signingInput, Uint8List signatureBytes) {
  if (jwk.kty != 'EC') return false;
  if (jwk.raw['crv'] != 'P-256') return false;
  final x = jwk.raw['x'];
  final y = jwk.raw['y'];
  if (x is! String || y is! String) return false;
  // JOSE ES256 signatures are raw R||S, 32 bytes each (RFC 7518 §3.4) —
  // not the ASN.1 DER pair pointycastle's own signer produces.
  if (signatureBytes.length != 64) return false;

  final domain = ECDomainParameters('prime256v1');
  final point = domain.curve.createPoint(
    _bytesToBigInt(_base64UrlDecode(x)),
    _bytesToBigInt(_base64UrlDecode(y)),
  );
  final publicKey = ECPublicKey(point, domain);
  final signature = ECSignature(
    _bytesToBigInt(signatureBytes.sublist(0, 32)),
    _bytesToBigInt(signatureBytes.sublist(32, 64)),
  );
  final signer = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
  try {
    return signer.verifySignature(signingInput, signature);
  } on Object {
    return false;
  }
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
