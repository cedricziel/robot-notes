import 'package:server/src/oauth/consent_page.dart';
import 'package:test/test.dart';

ConsentPageParams _params({
  String clientName = 'Desk Assistant',
  String? state,
  String? resource,
  Set<String> scopes = const {'notes:read', 'notes:write'},
}) =>
    ConsentPageParams(
      clientId: 'client-123',
      clientName: clientName,
      redirectUri: 'https://agent.example/callback',
      responseType: 'code',
      codeChallenge: 'challenge-abc',
      codeChallengeMethod: 'S256',
      scopes: scopes,
      state: state,
      resource: resource,
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
  });
}
