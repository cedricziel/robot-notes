import 'package:app/src/auth/web_oauth_callback.dart';
import 'package:app/src/config/config_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractWebOAuthCallback', () {
    test('returns null when the URL has no OAuth query parameters', () {
      expect(
        extractWebOAuthCallback(Uri.parse('https://notes.example/')),
        isNull,
      );
    });

    test('extracts code and state on success', () {
      final callback = extractWebOAuthCallback(
        Uri.parse('https://notes.example/?code=abc&state=xyz'),
      );
      expect(callback, isNotNull);
      expect(callback!.code, 'abc');
      expect(callback.state, 'xyz');
      expect(callback.error, isNull);
    });

    test('extracts an error and state on failure', () {
      final callback = extractWebOAuthCallback(
        Uri.parse('https://notes.example/?error=access_denied&state=xyz'),
      );
      expect(callback, isNotNull);
      expect(callback!.error, 'access_denied');
      expect(callback.code, isNull);
    });
  });

  group('ConfigStore pending OIDC login', () {
    test('round-trips a pending login', () async {
      final store = InMemoryConfigStore();
      const pending = PendingOidcLogin(
        baseUrl: 'https://notes.example',
        clientId: 'client-1',
        codeVerifier: 'verifier-xyz',
        state: 'state-abc',
        redirectUri: 'https://notes.example/',
      );

      await store.writePendingOidcLogin(pending);
      final read = await store.readPendingOidcLogin();

      expect(read?.baseUrl, pending.baseUrl);
      expect(read?.clientId, pending.clientId);
      expect(read?.codeVerifier, pending.codeVerifier);
      expect(read?.state, pending.state);
      expect(read?.redirectUri, pending.redirectUri);
    });

    test('is null before anything is written', () async {
      final store = InMemoryConfigStore();
      expect(await store.readPendingOidcLogin(), isNull);
    });

    test('clearPendingOidcLogin removes it', () async {
      final store = InMemoryConfigStore();
      await store.writePendingOidcLogin(
        const PendingOidcLogin(
          baseUrl: 'https://notes.example',
          clientId: 'client-1',
          codeVerifier: 'verifier-xyz',
          state: 'state-abc',
          redirectUri: 'https://notes.example/',
        ),
      );

      await store.clearPendingOidcLogin();

      expect(await store.readPendingOidcLogin(), isNull);
    });
  });
}
