import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/constant_time.dart';
import 'package:server/src/oauth/oauth_crypto.dart';
import 'package:server/src/oauth/oauth_records.dart';
import 'package:server/src/oauth/store_support.dart';

/// Number of bytes of randomness in a minted `client_id`. 16 bytes = 128
/// bits, matching RFC 7591's entropy expectation.
const int kClientIdBytes = 16;

/// Number of bytes of randomness in a minted client secret. 32 bytes =
/// 256 bits.
const int kClientSecretBytes = 32;

/// Result of [ClientStore.register]: the persisted client record plus the
/// raw secret, which is returned exactly once and never persisted.
@immutable
class RegisteredClient {
  /// Pairs a persisted [client] with its raw [clientSecret] (`null` for a
  /// public client).
  const RegisteredClient({required this.client, this.clientSecret});

  /// The persisted client record (secret stored only as a hash).
  final OAuthClient client;

  /// The raw client secret, or `null` for `token_endpoint_auth_method:
  /// none`. Callers must surface this to the registrant immediately; it
  /// cannot be recovered afterwards.
  final String? clientSecret;
}

/// Filesystem-backed store of Dynamic-Client-Registration records.
///
/// On-disk layout: each client lives at `<dir>/<clientId>.json`, following
/// the same tmp+fsync+rename and per-key mutex pattern as `InviteStore`.
class ClientStore {
  /// Constructs a store rooted at [dir] (created on first write). [clock]
  /// stamps registration time. [random] supplies the entropy for minted
  /// client ids and secrets; tests inject a deterministic source.
  ClientStore({
    required this.dir,
    Clock clock = const Clock(),
    Random? random,
    Logger? logger,
  })  : _clock = clock,
        _random = random ?? Random.secure(),
        _log = logger ?? Logger('oauth.client_store');

  /// Filesystem directory holding `*.json` client files.
  final Directory dir;

  final Clock _clock;
  final Random _random;
  final Logger _log;
  final _mutex = KeyedMutex();

  /// Mints a new client, persists it, and returns the record together
  /// with the raw secret (`null` when [tokenEndpointAuthMethod] is
  /// `none`).
  Future<RegisteredClient> register({
    required String clientName,
    required List<String> redirectUris,
    required String tokenEndpointAuthMethod,
    required List<String> grantTypes,
    required List<String> responseTypes,
  }) async {
    final clientId = generateRandomToken(_random, kClientIdBytes);
    final rawSecret = tokenEndpointAuthMethod == 'none'
        ? null
        : generateRandomToken(_random, kClientSecretBytes);
    final client = OAuthClient(
      clientId: clientId,
      clientName: clientName,
      redirectUris: List.unmodifiable(redirectUris),
      tokenEndpointAuthMethod: tokenEndpointAuthMethod,
      grantTypes: List.unmodifiable(grantTypes),
      responseTypes: List.unmodifiable(responseTypes),
      clientSecretHash: rawSecret == null ? null : hashSecret(rawSecret),
      createdAt: _clock.nowUtc(),
    );
    await _mutex.run(
      clientId,
      () => atomicWriteJsonFile(_fileFor(clientId), client.toJson()),
    );
    return RegisteredClient(client: client, clientSecret: rawSecret);
  }

  /// Returns the client for [clientId], or `null` if [clientId] is not a
  /// well-formed minted id, it does not exist, or its file fails to parse
  /// (logged and skipped).
  Future<OAuthClient?> get(String clientId) async {
    if (!isSafeStoreKey(clientId)) return null;
    final file = _fileFor(clientId);
    if (!file.existsSync()) return null;
    try {
      return await _readFile(file);
    } on Exception catch (e) {
      _log.warning('Skipping malformed OAuth client ${file.path}: $e');
      return null;
    }
  }

  /// Constant-time-compares [rawSecret] against [client]'s stored hash.
  /// Always `false` for a public client (no stored hash).
  bool verifySecret(OAuthClient client, String rawSecret) {
    final hash = client.clientSecretHash;
    if (hash == null) return false;
    return constantTimeEquals(hash, hashSecret(rawSecret));
  }

  File _fileFor(String clientId) => File('${dir.path}/$clientId.json');

  Future<OAuthClient> _readFile(File file) async {
    final raw = await file.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return OAuthClient.fromJson(json);
  }
}
