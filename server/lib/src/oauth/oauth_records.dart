import 'package:meta/meta.dart';

List<String> _stringList(Object? json) =>
    (json! as List<dynamic>).cast<String>();

DateTime _parseUtc(Object? json) => DateTime.parse(json! as String).toUtc();

DateTime? _parseUtcOrNull(Object? json) =>
    json == null ? null : DateTime.parse(json as String).toUtc();

/// A Dynamic-Client-Registration record. Persisted at
/// `<dataDir>/oauth/clients/<clientId>.json`.
@immutable
class OAuthClient {
  /// Constructs a client record.
  const OAuthClient({
    required this.clientId,
    required this.clientName,
    required this.redirectUris,
    required this.tokenEndpointAuthMethod,
    required this.grantTypes,
    required this.responseTypes,
    required this.clientSecretHash,
    required this.createdAt,
  });

  /// Parses a client record from its on-disk JSON form.
  factory OAuthClient.fromJson(Map<String, dynamic> json) => OAuthClient(
        clientId: json['client_id'] as String,
        clientName: json['client_name'] as String,
        redirectUris: _stringList(json['redirect_uris']),
        tokenEndpointAuthMethod: json['token_endpoint_auth_method'] as String,
        grantTypes: _stringList(json['grant_types']),
        responseTypes: _stringList(json['response_types']),
        clientSecretHash: json['client_secret_hash'] as String?,
        createdAt: _parseUtc(json['created_at']),
      );

  /// Opaque public identifier minted at registration.
  final String clientId;

  /// Operator-supplied display name, echoed on the consent page.
  final String clientName;

  /// Registered redirect URIs; the authorize step matches one exactly.
  final List<String> redirectUris;

  /// One of `none`, `client_secret_post`, `client_secret_basic`.
  final String tokenEndpointAuthMethod;

  /// Grant types this client is allowed to use.
  final List<String> grantTypes;

  /// Response types this client is allowed to request.
  final List<String> responseTypes;

  /// SHA-256 hex digest of the client secret, or `null` for a public
  /// client (`tokenEndpointAuthMethod == 'none'`). The raw secret is
  /// never persisted.
  final String? clientSecretHash;

  /// Registration time (UTC).
  final DateTime createdAt;

  /// JSON serialization (matches the on-disk file format).
  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'client_name': clientName,
        'redirect_uris': redirectUris,
        'token_endpoint_auth_method': tokenEndpointAuthMethod,
        'grant_types': grantTypes,
        'response_types': responseTypes,
        'client_secret_hash': clientSecretHash,
        'created_at': createdAt.toUtc().toIso8601String(),
      };
}

/// A minted, single-use authorization code. Persisted at
/// `<dataDir>/oauth/codes/<sha256(code)>.json`.
@immutable
class AuthorizationCode {
  /// Constructs an authorization-code record.
  const AuthorizationCode({
    required this.codeHash,
    required this.clientId,
    required this.redirectUri,
    required this.codeChallenge,
    required this.scopes,
    required this.resource,
    required this.actor,
    required this.grantId,
    required this.createdAt,
    required this.expiresAt,
    this.consumedAt,
  });

  /// Parses an authorization-code record from its on-disk JSON form.
  factory AuthorizationCode.fromJson(Map<String, dynamic> json) =>
      AuthorizationCode(
        codeHash: json['code_hash'] as String,
        clientId: json['client_id'] as String,
        redirectUri: json['redirect_uri'] as String,
        codeChallenge: json['code_challenge'] as String,
        scopes: _stringList(json['scopes']).toSet(),
        resource: json['resource'] as String,
        actor: json['actor'] as String,
        grantId: json['grant_id'] as String,
        createdAt: _parseUtc(json['created_at']),
        expiresAt: _parseUtc(json['expires_at']),
        consumedAt: _parseUtcOrNull(json['consumed_at']),
      );

  /// SHA-256 hex digest of the raw code; also the file stem.
  final String codeHash;

  /// Client the code was minted for.
  final String clientId;

  /// Redirect URI the code is bound to.
  final String redirectUri;

  /// PKCE `code_challenge` supplied at `/oauth/authorize`.
  final String codeChallenge;

  /// Granted scopes.
  final Set<String> scopes;

  /// Resource indicator the code is bound to (the MCP resource URL).
  final String resource;

  /// Actor name the resulting tokens will write under.
  final String actor;

  /// Identifier shared by every code/token minted from the same consent,
  /// so reuse detection and revocation can cascade across the family.
  final String grantId;

  /// Mint time (UTC).
  final DateTime createdAt;

  /// Expiry time (UTC), `createdAt` plus `CodeStore.codeTtl`.
  final DateTime expiresAt;

  /// Time the code was exchanged, or `null` while still usable.
  final DateTime? consumedAt;

  /// Whether [now] falls past [expiresAt].
  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  /// Returns a copy with [consumedAt] applied.
  AuthorizationCode consumedCopy(DateTime when) => AuthorizationCode(
        codeHash: codeHash,
        clientId: clientId,
        redirectUri: redirectUri,
        codeChallenge: codeChallenge,
        scopes: scopes,
        resource: resource,
        actor: actor,
        grantId: grantId,
        createdAt: createdAt,
        expiresAt: expiresAt,
        consumedAt: when,
      );

  /// JSON serialization (matches the on-disk file format).
  Map<String, dynamic> toJson() => {
        'code_hash': codeHash,
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'code_challenge': codeChallenge,
        'scopes': scopes.toList()..sort(),
        'resource': resource,
        'actor': actor,
        'grant_id': grantId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'consumed_at': consumedAt?.toUtc().toIso8601String(),
      };
}

/// Distinguishes access from refresh tokens sharing the same on-disk
/// record shape.
enum OAuthTokenKind {
  /// A bearer credential accepted at `/mcp`.
  access,

  /// A credential exchanged at `/oauth/token` for a new token pair.
  refresh;

  /// Parses the on-disk `kind` string.
  static OAuthTokenKind fromJson(String json) =>
      values.firstWhere((k) => k.name == json);
}

/// A minted access or refresh token. Persisted at
/// `<dataDir>/oauth/tokens/<sha256(token)>.json`.
@immutable
class OAuthToken {
  /// Constructs a token record.
  const OAuthToken({
    required this.tokenHash,
    required this.kind,
    required this.clientId,
    required this.actor,
    required this.scopes,
    required this.resource,
    required this.grantId,
    required this.createdAt,
    required this.expiresAt,
    this.revokedAt,
    this.rotatedAt,
  });

  /// Parses a token record from its on-disk JSON form.
  factory OAuthToken.fromJson(Map<String, dynamic> json) => OAuthToken(
        tokenHash: json['token_hash'] as String,
        kind: OAuthTokenKind.fromJson(json['kind'] as String),
        clientId: json['client_id'] as String,
        actor: json['actor'] as String,
        scopes: _stringList(json['scopes']).toSet(),
        resource: json['resource'] as String,
        grantId: json['grant_id'] as String,
        createdAt: _parseUtc(json['created_at']),
        expiresAt: _parseUtc(json['expires_at']),
        revokedAt: _parseUtcOrNull(json['revoked_at']),
        rotatedAt: _parseUtcOrNull(json['rotated_at']),
      );

  /// SHA-256 hex digest of the raw token; also the file stem.
  final String tokenHash;

  /// Whether this record is an access or a refresh token.
  final OAuthTokenKind kind;

  /// Client the token was issued to.
  final String clientId;

  /// Actor name every call made with this token writes under.
  final String actor;

  /// Granted scopes.
  final Set<String> scopes;

  /// Resource indicator the token is bound to (the MCP resource URL).
  final String resource;

  /// Identifier shared by every code/token minted from the same consent.
  final String grantId;

  /// Issue time (UTC).
  final DateTime createdAt;

  /// Expiry time (UTC): `createdAt` plus the access or refresh TTL.
  final DateTime expiresAt;

  /// Time the token was revoked, or `null` while still live.
  final DateTime? revokedAt;

  /// For refresh tokens, the time it was rotated away by a refresh; always
  /// `null` for access tokens.
  final DateTime? rotatedAt;

  /// Whether [now] falls past [expiresAt].
  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  /// Whether [revokedAt] is non-null.
  bool get isRevoked => revokedAt != null;

  /// Whether [rotatedAt] is non-null.
  bool get isRotated => rotatedAt != null;

  /// Returns a copy with [revokedAt] applied, unless already revoked.
  OAuthToken revokedCopy(DateTime when) => OAuthToken(
        tokenHash: tokenHash,
        kind: kind,
        clientId: clientId,
        actor: actor,
        scopes: scopes,
        resource: resource,
        grantId: grantId,
        createdAt: createdAt,
        expiresAt: expiresAt,
        revokedAt: revokedAt ?? when,
        rotatedAt: rotatedAt,
      );

  /// Returns a copy with [rotatedAt] applied.
  OAuthToken rotatedCopy(DateTime when) => OAuthToken(
        tokenHash: tokenHash,
        kind: kind,
        clientId: clientId,
        actor: actor,
        scopes: scopes,
        resource: resource,
        grantId: grantId,
        createdAt: createdAt,
        expiresAt: expiresAt,
        revokedAt: revokedAt,
        rotatedAt: when,
      );

  /// JSON serialization (matches the on-disk file format).
  Map<String, dynamic> toJson() => {
        'token_hash': tokenHash,
        'kind': kind.name,
        'client_id': clientId,
        'actor': actor,
        'scopes': scopes.toList()..sort(),
        'resource': resource,
        'grant_id': grantId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'revoked_at': revokedAt?.toUtc().toIso8601String(),
        'rotated_at': rotatedAt?.toUtc().toIso8601String(),
      };
}
