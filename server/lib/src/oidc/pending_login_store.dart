import 'dart:math';

import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/pkce.dart';

/// Bytes of randomness for each of `state`, `nonce`, and the PKCE code
/// verifier. 32 bytes = 256 bits.
const int _kEntropyBytes = 32;

/// A single OIDC login in progress, bound to the `/oauth/authorize`
/// consent request it will complete on success.
@immutable
class PendingLogin {
  /// Creates a pending login record.
  const PendingLogin({
    required this.state,
    required this.nonce,
    required this.codeVerifier,
    required this.codeChallenge,
    required this.consentRequest,
    required this.createdAt,
  });

  /// Opaque anti-CSRF value round-tripped through the provider's
  /// authorize redirect and matched on callback.
  final String state;

  /// Value bound into the ID token's `nonce` claim, checked on callback
  /// to bind this specific browser round-trip to the returned token.
  final String nonce;

  /// This login's own PKCE verifier, used when exchanging the code at
  /// the provider's token endpoint.
  final String codeVerifier;

  /// The S256 challenge derived from [codeVerifier], sent in the
  /// authorize redirect.
  final String codeChallenge;

  /// The original `/oauth/authorize` request's parameters, replayed to
  /// complete consent for that client once OIDC login succeeds.
  final Map<String, String> consentRequest;

  /// When this login was started, for TTL enforcement.
  final DateTime createdAt;
}

/// Process-local, non-persisted store of in-flight OIDC logins, keyed by
/// `state`. Entries expire after [ttl] (10 minutes per the `oidc-login`
/// spec) and are single-use: [take] removes the entry it returns.
class PendingLoginStore {
  /// Creates a store. [clock] and [random] are injectable for
  /// deterministic tests.
  PendingLoginStore({
    Clock clock = const Clock(),
    Random? random,
    this.ttl = const Duration(minutes: 10),
  })  : _clock = clock,
        _random = random ?? Random.secure();

  /// How long a pending login remains valid after [start].
  final Duration ttl;

  final Clock _clock;
  final Random _random;
  final Map<String, PendingLogin> _byState = {};

  /// Starts a new pending login bound to [consentRequest], minting a
  /// fresh `state`, `nonce`, and PKCE pair, and persists it.
  PendingLogin start({required Map<String, String> consentRequest}) {
    final codeVerifier = generateRandomToken(_random, _kEntropyBytes);
    final pending = PendingLogin(
      state: generateRandomToken(_random, _kEntropyBytes),
      nonce: generateRandomToken(_random, _kEntropyBytes),
      codeVerifier: codeVerifier,
      codeChallenge: pkceS256Challenge(codeVerifier),
      consentRequest: Map.unmodifiable(consentRequest),
      createdAt: _clock.nowUtc(),
    );
    _byState[pending.state] = pending;
    return pending;
  }

  /// Removes and returns the pending login for [state], or `null` when
  /// unknown or expired. A second call for the same [state] always
  /// returns `null` — this is a single-use lookup.
  PendingLogin? take(String state) {
    final pending = _byState.remove(state);
    if (pending == null) return null;
    if (_clock.nowUtc().difference(pending.createdAt) >= ttl) return null;
    return pending;
  }
}
