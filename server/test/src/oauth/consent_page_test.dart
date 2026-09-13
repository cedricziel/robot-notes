import 'package:server/src/oauth/consent_page.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

ConsentPageParams _params({
  String clientName = 'Desk Assistant',
  String? state,
  String? resource,
  Set<String> scopes = const {'notes:read', 'notes:write'},
  String redirectUri = 'https://agent.example/callback',
  String serverHost = 'notes.example',
}) =>
    ConsentPageParams(
      clientId: 'client-123',
      clientName: clientName,
      redirectUri: redirectUri,
      responseType: 'code',
      codeChallenge: 'challenge-abc',
      codeChallengeMethod: 'S256',
      scopes: scopes,
      state: state,
      resource: resource,
      serverHost: serverHost,
    );

void main() {
  group('renderConsentPage', () {
    test('escapes a script tag in the client name', () {
      final html = renderConsentPage(
        _params(clientName: '<script>alert(1)</script>'),
      );
      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;'));
    });

    test('escapes state', () {
      final html = renderConsentPage(_params(state: '"><script>x</script>'));
      expect(html, isNot(contains('"><script>x</script>')));
      expect(html, contains('&quot;&gt;&lt;script&gt;x&lt;/script&gt;'));
    });

    test('renders the requested scopes', () {
      final html = renderConsentPage(_params(scopes: const {'notes:read'}));
      expect(html, contains('notes:read'));
      expect(html, isNot(contains('notes:write')));
    });

    test('contains the api_key password input', () {
      final html = renderConsentPage(_params());
      expect(html, contains('type="password"'));
      expect(html, contains('name="api_key"'));
    });

    test('contains the actor input prefilled with the client name', () {
      final html = renderConsentPage(_params());
      expect(html, contains('name="actor"'));
      expect(html, contains('value="Desk Assistant"'));
    });

    test('carries every hidden authorization parameter forward', () {
      final html = renderConsentPage(
        _params(state: 'xyz', resource: 'https://notes.example/mcp'),
      );
      expect(html, contains('name="client_id" value="client-123"'));
      expect(
        html,
        contains('name="redirect_uri" value="https://agent.example/callback"'),
      );
      expect(html, contains('name="response_type" value="code"'));
      expect(
        html,
        contains('name="code_challenge" value="challenge-abc"'),
      );
      expect(
        html,
        contains('name="code_challenge_method" value="S256"'),
      );
      expect(html, contains('name="state" value="xyz"'));
      expect(
        html,
        contains('name="scope" value="notes:read notes:write"'),
      );
      expect(
        html,
        contains('name="resource" value="https://notes.example/mcp"'),
      );
    });

    test('omits the state hidden field when state is absent', () {
      final html = renderConsentPage(_params());
      expect(html, isNot(contains('name="state"')));
    });

    test('shows an error banner when given an error', () {
      final html =
          renderConsentPage(_params(), errorMessage: 'Incorrect API key.');
      expect(html, contains('Incorrect API key.'));
    });

    test('contains no error banner when no error is given', () {
      final html = renderConsentPage(_params());
      expect(html, isNot(contains('class="error"')));
    });

    test('has no script tags of its own', () {
      final html = renderConsentPage(_params());
      expect(html, isNot(contains('<script')));
    });

    group('when OIDC is configured', () {
      test('renders a sign-in link instead of the api_key form', () {
        final html = renderConsentPage(_params(), oidcConfigured: true);
        expect(html, isNot(contains('name="api_key"')));
        expect(html, isNot(contains('type="password"')));
        expect(html, contains('href="${Routes.oauthOidcLogin}'));
      });

      test('the sign-in link forwards every authorization parameter', () {
        final html = renderConsentPage(
          _params(state: 'xyz', resource: 'https://notes.example/mcp'),
          oidcConfigured: true,
        );
        expect(html, contains('client_id=client-123'));
        expect(
          html,
          contains('redirect_uri=${Uri.encodeQueryComponent(
            'https://agent.example/callback',
          )}'),
        );
        expect(html, contains('response_type=code'));
        expect(html, contains('code_challenge=challenge-abc'));
        expect(html, contains('code_challenge_method=S256'));
        expect(html, contains('state=xyz'));
        expect(
          html,
          contains('scope=${Uri.encodeQueryComponent(
            'notes:read notes:write',
          )}'),
        );
        expect(
          html,
          contains(
            'resource=${Uri.encodeQueryComponent('https://notes.example/mcp')}',
          ),
        );
      });

      test('omits state from the sign-in link when absent', () {
        final html = renderConsentPage(_params(), oidcConfigured: true);
        expect(html, isNot(contains('state=')));
      });

      test('still shows an error banner when given an error', () {
        final html = renderConsentPage(
          _params(),
          oidcConfigured: true,
          errorMessage: 'Login failed. Please try again.',
        );
        expect(html, contains('Login failed. Please try again.'));
      });
    });

    test('renders the api_key form when OIDC is not configured', () {
      final html = renderConsentPage(_params());
      expect(html, contains('name="api_key"'));
      expect(html, isNot(contains(Routes.oauthOidcLogin)));
    });

    group('branding', () {
      test('shows the server host', () {
        final html = renderConsentPage(_params(serverHost: 'notes.58lab.org'));
        expect(html, contains('notes.58lab.org'));
      });
    });

    group('redirect destination', () {
      test('shows the full redirect_uri before deciding', () {
        final html = renderConsentPage(
          _params(redirectUri: 'https://agent.example/callback?x=1'),
        );
        expect(html, contains('https://agent.example/callback?x=1'));
      });

      test('escapes the redirect_uri', () {
        final html = renderConsentPage(
          _params(redirectUri: 'https://agent.example/<script>x</script>'),
        );
        expect(html, isNot(contains('<script>x</script>')));
      });
    });

    group('cancel', () {
      test('a cancel link points back to redirect_uri with access_denied', () {
        final html = renderConsentPage(_params());
        expect(
          html,
          contains(
            'href="https://agent.example/callback?error=access_denied"',
          ),
        );
      });

      test('the cancel link preserves state', () {
        final html = renderConsentPage(_params(state: 'xyz'));
        expect(
          html,
          contains(
            'href="https://agent.example/callback?error=access_denied&amp;state=xyz"',
          ),
        );
      });

      test('appends to an existing query string rather than replacing it', () {
        final html = renderConsentPage(
          _params(redirectUri: 'https://agent.example/callback?x=1'),
        );
        expect(
          html,
          contains(
            'href="https://agent.example/callback?x=1&amp;error=access_denied"',
          ),
        );
      });

      test('is present next to the sign-in link when OIDC is configured', () {
        final html = renderConsentPage(_params(), oidcConfigured: true);
        expect(html, contains('class="cancel"'));
        expect(html, contains('error=access_denied'));
      });
    });
  });
}
