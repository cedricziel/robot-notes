import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('Routes', () {
    test('exposes the documented v1 paths', () {
      expect(Routes.healthz, '/healthz');
      expect(Routes.notes, '/notes');
      expect(Routes.search, '/search');
      expect(Routes.ws, '/ws');
      expect(Routes.invites, '/invites');
    });

    test('builds note-scoped paths from an id', () {
      const id = '01HXY00000000000000000000A';
      expect(Routes.note(id), '/notes/$id');
      expect(Routes.noteLock(id), '/notes/$id/lock');
    });

    test('builds invite-scoped paths from a token', () {
      const tok = 'tok_abc';
      expect(Routes.invite(tok), '/invites/$tok');
      expect(Routes.inviteOnboarding(tok), '/invites/$tok/onboarding.txt');
    });

    test('exposes the MCP and OAuth paths', () {
      expect(Routes.mcp, '/mcp');
      expect(Routes.oauthRegister, '/oauth/register');
      expect(Routes.oauthAuthorize, '/oauth/authorize');
      expect(Routes.oauthToken, '/oauth/token');
      expect(Routes.oauthRevoke, '/oauth/revoke');
      expect(
        Routes.wellKnownProtectedResource,
        '/.well-known/oauth-protected-resource',
      );
      expect(
        Routes.wellKnownProtectedResourceMcp,
        '/.well-known/oauth-protected-resource/mcp',
      );
      expect(
        Routes.wellKnownAuthorizationServer,
        '/.well-known/oauth-authorization-server',
      );
    });

    test('exposes the OIDC login paths', () {
      expect(Routes.oauthOidcLogin, '/oauth/oidc/login');
      expect(Routes.oauthOidcCallback, '/oauth/oidc/callback');
    });

    test('exposes the databases paths', () {
      expect(Routes.databases, '/databases');
    });

    test('builds database-scoped paths from an id', () {
      const id = '01HXY00000000000000000000B';
      expect(Routes.database(id), '/databases/$id');
      expect(Routes.databaseQuery(id), '/databases/$id/query');
      expect(Routes.databaseRows(id), '/databases/$id/rows');
    });

    test('builds the note-properties path from an id', () {
      const id = '01HXY00000000000000000000A';
      expect(Routes.noteProperties(id), '/notes/$id/properties');
    });
  });
}
