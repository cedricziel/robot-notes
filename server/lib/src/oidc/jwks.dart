import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:server/src/oidc/discovery.dart';

/// The only JWS signing algorithms this server accepts for an ID token —
/// `alg=none` and every symmetric or otherwise-unlisted algorithm are
/// rejected before signature verification is even attempted, per the
/// `oidc-login` capability.
const Set<String> _allowedJwsAlgorithms = {'RS256', 'ES256'};

/// Whether [alg] is one of the JWS algorithms this server accepts.
bool isAllowedJwsAlgorithm(String alg) => _allowedJwsAlgorithms.contains(alg);

/// A single entry from a provider's JSON Web Key Set, keeping every field
/// (in [raw]) so signature verification can read the algorithm-specific
/// key material (`n`/`e` for RSA, `x`/`y`/`crv` for EC).
@immutable
class Jwk {
  /// Creates a key record from a decoded JWKS entry.
  const Jwk({
    required this.kid,
    required this.kty,
    required this.raw,
    this.alg,
  });

  /// Key id, matched against an ID token's JWS header `kid`.
  final String kid;

  /// Key type (`RSA`, `EC`, ...).
  final String kty;

  /// The key's declared algorithm, when present.
  final String? alg;

  /// The full JWK JSON object.
  final Map<String, dynamic> raw;
}

/// Fetches and caches a provider's JWKS document, indexed by `kid`.
///
/// A lookup for a `kid` not currently cached triggers exactly one refetch
/// (to tolerate the provider rotating in a new signing key without a
/// server restart) before giving up.
class JwksCache {
  /// Creates a cache for the JWKS document at [jwksUri], using [httpGet]
  /// to fetch it (real HTTP in production, a fake in tests).
  JwksCache({required this.jwksUri, required HttpGet httpGet})
      : _httpGet = httpGet;

  /// The provider's JWKS endpoint, from its discovery document.
  final String jwksUri;

  final HttpGet _httpGet;
  Map<String, Jwk> _keysById = const {};

  /// Returns the key named [kid], fetching (or refetching, if already
  /// populated) the JWKS document at most once for this call.
  Future<Jwk?> keyForId(String kid) async {
    if (_keysById.containsKey(kid)) return _keysById[kid];
    await _refresh();
    return _keysById[kid];
  }

  Future<void> _refresh() async {
    final body = await _httpGet(Uri.parse(jwksUri));
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final keys = (decoded['keys'] as List).cast<Map<String, dynamic>>();
    _keysById = {
      for (final key in keys)
        if (key['kid'] is String)
          key['kid'] as String: Jwk(
            kid: key['kid'] as String,
            kty: key['kty'] as String? ?? '',
            alg: key['alg'] as String?,
            raw: key,
          ),
    };
  }
}
