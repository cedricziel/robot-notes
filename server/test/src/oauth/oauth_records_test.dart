import 'package:server/src/oauth/oauth_records.dart';
import 'package:test/test.dart';

Map<String, dynamic> _clientJson({Object? redirectUris, Object? createdAt}) => {
      'client_id': 'client-1',
      'client_name': 'Desk Assistant',
      'redirect_uris': redirectUris ?? ['https://agent.example/callback'],
      'token_endpoint_auth_method': 'none',
      'grant_types': ['authorization_code'],
      'response_types': ['code'],
      'client_secret_hash': null,
      'created_at': createdAt ?? '2026-04-25T10:00:00.000Z',
    };

Map<String, dynamic> _codeJson({Object? scopes}) => {
      'code_hash': 'hash-1',
      'client_id': 'client-1',
      'redirect_uri': 'https://agent.example/callback',
      'code_challenge': 'challenge',
      'scopes': scopes ?? ['notes:read'],
      'resource': 'https://notes.example/mcp',
      'actor': 'desk-assistant',
      'grant_id': 'grant-1',
      'created_at': '2026-04-25T10:00:00.000Z',
      'expires_at': '2026-04-25T10:10:00.000Z',
      'consumed_at': null,
      'revoked_at': null,
    };

Map<String, dynamic> _tokenJson({Object? scopes}) => {
      'token_hash': 'hash-1',
      'kind': 'access',
      'client_id': 'client-1',
      'actor': 'desk-assistant',
      'scopes': scopes ?? ['notes:read'],
      'resource': 'https://notes.example/mcp',
      'grant_id': 'grant-1',
      'created_at': '2026-04-25T10:00:00.000Z',
      'expires_at': '2026-04-25T11:00:00.000Z',
      'revoked_at': null,
      'rotated_at': null,
    };

void main() {
  group('OAuthClient', () {
    test('round-trips through JSON', () {
      final client = OAuthClient.fromJson(_clientJson());
      final decoded = OAuthClient.fromJson(client.toJson());
      expect(decoded.clientId, client.clientId);
      expect(decoded.redirectUris, client.redirectUris);
      expect(decoded.createdAt, client.createdAt);
    });

    test('normalizes a non-UTC created_at to UTC', () {
      final client = OAuthClient.fromJson(
        _clientJson(createdAt: '2026-04-25T12:00:00.000+02:00'),
      );
      expect(client.createdAt.isUtc, isTrue);
      expect(client.createdAt, DateTime.utc(2026, 4, 25, 10));
    });

    test(
        'a non-string element in redirect_uris throws while parsing, not '
        'while it is later read', () {
      expect(
        () => OAuthClient.fromJson(_clientJson(redirectUris: [1])),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('AuthorizationCode', () {
    test('round-trips through JSON, including consumedAt', () {
      final code = AuthorizationCode.fromJson(_codeJson());
      final consumed = code.consumedCopy(DateTime.utc(2026, 4, 25, 10, 5));
      final decoded = AuthorizationCode.fromJson(consumed.toJson());
      expect(decoded.consumedAt, consumed.consumedAt);
      expect(decoded.codeHash, code.codeHash);
    });

    test('isExpired is true exactly at the boundary', () {
      final code = AuthorizationCode.fromJson(_codeJson());
      expect(code.isExpired(code.expiresAt), isTrue);
      expect(
        code.isExpired(code.expiresAt.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('consumedCopy preserves every other field', () {
      final code = AuthorizationCode.fromJson(_codeJson());
      final consumed = code.consumedCopy(DateTime.utc(2026, 4, 25, 10, 5));
      expect(consumed.codeHash, code.codeHash);
      expect(consumed.clientId, code.clientId);
      expect(consumed.redirectUri, code.redirectUri);
      expect(consumed.codeChallenge, code.codeChallenge);
      expect(consumed.grantId, code.grantId);
      expect(consumed.scopes, code.scopes);
      expect(consumed.consumedAt, DateTime.utc(2026, 4, 25, 10, 5));
    });

    test(
        'revokedCopy is idempotent: a second call keeps the first '
        'timestamp', () {
      final code = AuthorizationCode.fromJson(_codeJson());
      final first = code.revokedCopy(DateTime.utc(2026, 4, 25, 10, 1));
      final second = first.revokedCopy(DateTime.utc(2026, 4, 25, 10, 2));
      expect(second.revokedAt, DateTime.utc(2026, 4, 25, 10, 1));
      expect(second.isRevoked, isTrue);
    });

    test(
        'a non-string element in scopes throws while parsing, not while '
        'it is later read', () {
      expect(
        () => AuthorizationCode.fromJson(_codeJson(scopes: [1])),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('OAuthToken', () {
    test('round-trips through JSON', () {
      final token = OAuthToken.fromJson(_tokenJson());
      final decoded = OAuthToken.fromJson(token.toJson());
      expect(decoded.tokenHash, token.tokenHash);
      expect(decoded.kind, token.kind);
      expect(decoded.scopes, token.scopes);
    });

    test('isExpired is true exactly at the boundary', () {
      final token = OAuthToken.fromJson(_tokenJson());
      expect(token.isExpired(token.expiresAt), isTrue);
      expect(
        token.isExpired(token.expiresAt.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test(
        'revokedCopy is idempotent: a second call keeps the first '
        'timestamp', () {
      final token = OAuthToken.fromJson(_tokenJson());
      final first = token.revokedCopy(DateTime.utc(2026, 4, 25, 10, 1));
      final second = first.revokedCopy(DateTime.utc(2026, 4, 25, 10, 2));
      expect(second.revokedAt, DateTime.utc(2026, 4, 25, 10, 1));
      expect(second.isRevoked, isTrue);
    });

    test('rotatedCopy preserves revokedAt and every other field', () {
      final token = OAuthToken.fromJson(_tokenJson());
      final revoked = token.revokedCopy(DateTime.utc(2026, 4, 25, 10, 1));
      final rotated = revoked.rotatedCopy(DateTime.utc(2026, 4, 25, 10, 2));
      expect(rotated.revokedAt, DateTime.utc(2026, 4, 25, 10, 1));
      expect(rotated.rotatedAt, DateTime.utc(2026, 4, 25, 10, 2));
      expect(rotated.tokenHash, token.tokenHash);
      expect(rotated.scopes, token.scopes);
    });

    test(
        'a non-string element in scopes throws while parsing, not while '
        'it is later read', () {
      expect(
        () => OAuthToken.fromJson(_tokenJson(scopes: [1])),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
