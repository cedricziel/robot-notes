import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/invite_store.dart';
import 'package:test/test.dart';

import '../../../../routes/invites/[token]/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required InviteStore store,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/invites/abc'));
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<InviteStore>()).thenReturn(store);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-invite-revoke-test-');

void main() {
  late Directory tmp;
  late InviteStore store;

  setUp(() {
    tmp = _tempDir();
    store = InviteStore(
      inviteDir: Directory('${tmp.path}/invites'),
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('DELETE /invites/{token}', () {
    test('returns 204 and deletes a minted invite', () async {
      final invite = await store.mint(label: 'agent');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.delete, store: store),
        invite.token,
      );

      expect(res.statusCode, HttpStatus.noContent);
      expect(await store.get(invite.token), isNull);
    });

    test('returns 404 for unknown token', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.delete, store: store),
        'no-such-token',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'invite_not_found');
    });
  });

  group('method routing', () {
    test('rejects non-DELETE methods with 405', () async {
      for (final m in [
        HttpMethod.get,
        HttpMethod.post,
        HttpMethod.put,
        HttpMethod.patch,
      ]) {
        final res = await route.onRequest(
          _ctx(method: m, store: store),
          'some-token',
        );
        expect(res.statusCode, HttpStatus.methodNotAllowed, reason: '$m');
      }
    });
  });
}
