import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Test-only helpers for building real, cryptographically valid (and
/// deliberately invalid) signed ID tokens, so `verifyIdToken` is tested
/// against genuine RS256/ES256 signatures rather than mocked crypto.

String base64UrlEncodeNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _bigIntToBytes(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

SecureRandom _secureRandom() {
  final random = FortunaRandom();
  final seedSource = Random.secure();
  final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
  random.seed(KeyParameter(Uint8List.fromList(seeds)));
  return random;
}

class TestRsaKeyPair {
  TestRsaKeyPair(this.public, this.private, this.kid);
  final RSAPublicKey public;
  final RSAPrivateKey private;
  final String kid;

  Map<String, dynamic> get jwk => {
        'kty': 'RSA',
        'kid': kid,
        'alg': 'RS256',
        'use': 'sig',
        'n': base64UrlEncodeNoPad(_bigIntToBytes(public.modulus!)),
        'e': base64UrlEncodeNoPad(_bigIntToBytes(public.exponent!)),
      };
}

TestRsaKeyPair generateTestRsaKeyPair({String kid = 'rsa-key-1'}) {
  final keyGen = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
        _secureRandom(),
      ),
    );
  final pair = keyGen.generateKeyPair();
  return TestRsaKeyPair(pair.publicKey, pair.privateKey, kid);
}

class TestEcKeyPair {
  TestEcKeyPair(this.public, this.private, this.kid);
  final ECPublicKey public;
  final ECPrivateKey private;
  final String kid;

  Map<String, dynamic> get jwk {
    final x = public.Q!.x!.toBigInteger()!;
    final y = public.Q!.y!.toBigInteger()!;
    Uint8List fixedLength(BigInt v) {
      final bytes = _bigIntToBytes(v);
      if (bytes.length == 32) return bytes;
      return Uint8List(32)..setRange(32 - bytes.length, 32, bytes);
    }

    return {
      'kty': 'EC',
      'kid': kid,
      'alg': 'ES256',
      'use': 'sig',
      'crv': 'P-256',
      'x': base64UrlEncodeNoPad(fixedLength(x)),
      'y': base64UrlEncodeNoPad(fixedLength(y)),
    };
  }
}

TestEcKeyPair generateTestEcKeyPair({String kid = 'ec-key-1'}) {
  final domain = ECDomainParameters('prime256v1');
  final keyGen = ECKeyGenerator()
    ..init(
      ParametersWithRandom(ECKeyGeneratorParameters(domain), _secureRandom()),
    );
  final pair = keyGen.generateKeyPair();
  return TestEcKeyPair(pair.publicKey, pair.privateKey, kid);
}

String _segment(Map<String, dynamic> json) =>
    base64UrlEncodeNoPad(utf8.encode(jsonEncode(json)));

/// Builds a signed compact JWS (`header.payload.signature`) for [payload],
/// signed with [rsa]'s private key using RS256. Pass [algOverride] or
/// [kidOverride] to build a deliberately malformed header for negative
/// tests; pass [corruptSignature] to flip a byte for a bad-signature test.
String signRs256(
  Map<String, dynamic> payload,
  TestRsaKeyPair rsa, {
  String? algOverride,
  String? kidOverride,
  bool corruptSignature = false,
}) {
  final header = {
    'alg': algOverride ?? 'RS256',
    'typ': 'JWT',
    'kid': kidOverride ?? rsa.kid,
  };
  final signingInput = '${_segment(header)}.${_segment(payload)}';
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(rsa.private));
  final signature =
      signer.generateSignature(Uint8List.fromList(utf8.encode(signingInput)));
  final sigBytes = Uint8List.fromList(signature.bytes);
  if (corruptSignature) sigBytes[0] ^= 0xFF;
  return '$signingInput.${base64UrlEncodeNoPad(sigBytes)}';
}

/// As [signRs256], but ES256-signed with [ec]'s private key.
String signEs256(
  Map<String, dynamic> payload,
  TestEcKeyPair ec, {
  bool corruptSignature = false,
}) {
  final header = {'alg': 'ES256', 'typ': 'JWT', 'kid': ec.kid};
  final signingInput = '${_segment(header)}.${_segment(payload)}';
  final signer = ECDSASigner(SHA256Digest())
    ..init(
      true,
      ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(ec.private),
        _secureRandom(),
      ),
    );
  final signature = signer.generateSignature(
    Uint8List.fromList(utf8.encode(signingInput)),
  ) as ECSignature;
  // JOSE ES256 signature encoding is raw R||S, 32 bytes each — not the
  // ASN.1 DER pair pointycastle's ECSignature carries.
  Uint8List fixedLength(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    if (bytes.length == 32) return bytes;
    return Uint8List(32)..setRange(32 - bytes.length, 32, bytes);
  }

  final joseSig = Uint8List(64)
    ..setRange(0, 32, fixedLength(signature.r))
    ..setRange(32, 64, fixedLength(signature.s));
  if (corruptSignature) joseSig[0] ^= 0xFF;
  return '$signingInput.${base64UrlEncodeNoPad(joseSig)}';
}

/// Builds an unsigned (`alg: none`) compact token — three segments, empty
/// signature — for testing that it is rejected before any key lookup.
String buildNoneAlgToken(Map<String, dynamic> payload) {
  final header = {'alg': 'none', 'typ': 'JWT'};
  return '${_segment(header)}.${_segment(payload)}.';
}
