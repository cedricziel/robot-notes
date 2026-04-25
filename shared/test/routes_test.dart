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
  });
}
