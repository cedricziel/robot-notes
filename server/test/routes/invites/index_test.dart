import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/invite_store.dart';
import 'package:test/test.dart';

import '../../../routes/invites/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required InviteStore store,
  required Clock clock,
  Object? body,
  Map<String, String> headers = const {'host': 'localhost:8080'},
  Uri? uri,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(uri ?? Uri.parse('http://localhost/invites'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(req.json).thenAnswer((_) async => body);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<InviteStore>()).thenReturn(store);
  when(() => ctx.read<Clock>()).thenReturn(clock);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-invite-route-test-');

void main() {
  late Directory tmp;
  late InviteStore store;
  late Clock clock;

  setUp(() {
    tmp = _tempDir();
    clock = FixedClock.fixed(DateTime.utc(2026, 4, 25, 10));
    store = InviteStore(
      inviteDir: Directory('${tmp.path}/invites'),
      clock: clock,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('POST /invites', () {
    test('mints with default label and TTL', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{},
        ),
      );

      expect(res.statusCode, HttpStatus.created);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['token'], isA<String>());
      expect(body['label'], 'agent');
      expect(body['single_use'], true);
      expect(body['expired'], false);
      expect(body['expires_at'], isA<String>());
      expect(
        body['url'],
        startsWith('http://localhost:8080/invites/'),
      );
      expect(body['url'], endsWith('/onboarding.txt'));
    });

    test('mints with custom label', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{'label': 'orbit-bot'},
        ),
      );
      final body = await res.json() as Map<String, dynamic>;
      expect(body['label'], 'orbit-bot');
    });

    test('rejects non-string label', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{'label': 42},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('rejects whitespace-only label', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{'label': '   '},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('rejects non-positive ttl_seconds', () async {
      for (final bad in [0, -5]) {
        final res = await route.onRequest(
          _ctx(
            method: HttpMethod.post,
            store: store,
            clock: clock,
            body: <String, dynamic>{'ttl_seconds': bad},
          ),
        );
        expect(res.statusCode, HttpStatus.badRequest, reason: 'ttl=$bad');
      }
    });

    test('rejects ttl_seconds beyond kMaxInviteTtl', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{'ttl_seconds': kMaxInviteTtl.inSeconds + 1},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'invalid_ttl');
    });

    test('rejects non-integer ttl_seconds', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{'ttl_seconds': 'forever'},
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });

    test('honours valid ttl_seconds', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: <String, dynamic>{'ttl_seconds': 3600},
        ),
      );
      final body = await res.json() as Map<String, dynamic>;
      final expiresAt = DateTime.parse(body['expires_at']! as String);
      final now = clock.nowUtc();
      expect(
        expiresAt.difference(now).inSeconds,
        closeTo(3600, 5),
      );
    });

    test('rejects non-object body', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          store: store,
          clock: clock,
          body: ['not', 'an', 'object'],
        ),
      );
      expect(res.statusCode, HttpStatus.badRequest);
    });
  });

  group('GET /invites', () {
    test('returns empty list when none minted', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, store: store, clock: clock),
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['items'], isEmpty);
    });

    test('returns minted invites with summaries', () async {
      await store.mint(label: 'a');
      await store.mint(label: 'b');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, store: store, clock: clock),
      );
      final body = await res.json() as Map<String, dynamic>;
      final items = body['items']! as List<dynamic>;
      expect(items, hasLength(2));
      final first = items.first as Map<String, dynamic>;
      expect(first.keys, containsAll(['token', 'label', 'expired']));
      // Token never appears with a JSON key 'api_key' or similar — invites
      // route MUST NOT leak the configured bearer key.
      expect(body.toString(), isNot(contains('api_key')));
    });
  });

  group('method routing', () {
    test('rejects PUT/PATCH/DELETE/HEAD/OPTIONS with 405', () async {
      for (final m in [
        HttpMethod.put,
        HttpMethod.patch,
        HttpMethod.delete,
        HttpMethod.head,
        HttpMethod.options,
      ]) {
        final res = await route.onRequest(
          _ctx(method: m, store: store, clock: clock),
        );
        expect(res.statusCode, HttpStatus.methodNotAllowed, reason: '$m');
      }
    });
  });
}
