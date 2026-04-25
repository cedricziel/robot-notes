import 'dart:async';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/invite_store.dart';
import 'package:test/test.dart';

import '../../../../routes/invites/[token]/onboarding.txt.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

class _SettableClock implements Clock {
  _SettableClock(this._now);
  DateTime _now;
  void set(DateTime t) => _now = t.toUtc();
  @override
  DateTime nowUtc() => _now;
}

RequestContext _ctx({
  required HttpMethod method,
  required InviteStore store,
  required Clock clock,
  required Config config,
  Map<String, String> headers = const {'host': 'localhost:8080'},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(
    Uri.parse('http://localhost:8080/invites/X/onboarding.txt'),
  );
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<InviteStore>()).thenReturn(store);
  when(() => ctx.read<Clock>()).thenReturn(clock);
  when(() => ctx.read<Config>()).thenReturn(config);
  return ctx;
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-onboarding-route-test-');

const _config = Config(
  apiKey: 'rn_test_key',
  dataDir: '/tmp/data',
  port: 8080,
  lockTtlSeconds: 60,
);

void main() {
  late Directory tmp;
  late InviteStore store;
  late _SettableClock clock;

  setUp(() {
    tmp = _tempDir();
    clock = _SettableClock(DateTime.utc(2026, 4, 25, 10));
    store = InviteStore(
      inviteDir: Directory('${tmp.path}/invites'),
      clock: clock,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('GET /invites/{token}/onboarding.txt', () {
    test('200 returns plain-text bundle and burns invite', () async {
      final invite = await store.mint(label: 'orbit-bot');

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          store: store,
          clock: clock,
          config: _config,
        ),
        invite.token,
      );

      expect(res.statusCode, HttpStatus.ok);
      expect(
        res.headers[HttpHeaders.contentTypeHeader],
        'text/plain; charset=utf-8',
      );
      final body = await res.body();
      expect(body, contains('rn_test_key'));
      expect(body, contains('orbit-bot'));
      expect(body, contains('http://localhost:8080'));
      expect(body, contains(invite.token));

      // Underlying invite is now burned.
      final reloaded = await store.get(invite.token);
      expect(reloaded?.isBurned, isTrue);
    });

    test('second fetch returns 410 invite_burned', () async {
      final invite = await store.mint(label: 'agent');

      final first = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          store: store,
          clock: clock,
          config: _config,
        ),
        invite.token,
      );
      expect(first.statusCode, HttpStatus.ok);

      final second = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          store: store,
          clock: clock,
          config: _config,
        ),
        invite.token,
      );
      expect(second.statusCode, HttpStatus.gone);
      final body = await second.json() as Map<String, dynamic>;
      expect(body['error'], 'invite_burned');
    });

    test('unknown token returns 404 invite_not_found', () async {
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          store: store,
          clock: clock,
          config: _config,
        ),
        'no-such-token',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'invite_not_found');
    });

    test('expired invite returns 404 (not 410, even before burn)', () async {
      final invite = await store.mint(
        label: 'agent',
        ttl: const Duration(seconds: 60),
      );
      // Jump past expiry.
      clock.set(invite.expiresAt.add(const Duration(seconds: 1)));

      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          store: store,
          clock: clock,
          config: _config,
        ),
        invite.token,
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'invite_not_found');
    });

    test('non-GET methods return 405', () async {
      for (final m in [
        HttpMethod.post,
        HttpMethod.put,
        HttpMethod.delete,
        HttpMethod.patch,
      ]) {
        final res = await route.onRequest(
          _ctx(method: m, store: store, clock: clock, config: _config),
          'some-token',
        );
        expect(res.statusCode, HttpStatus.methodNotAllowed, reason: '$m');
      }
    });

    test('concurrent fetches — exactly one client gets 200, others 410',
        () async {
      final invite = await store.mint(label: 'agent');

      // Fire 4 simultaneous GETs for the same token.
      final futures = List.generate(
        4,
        (_) => route.onRequest(
          _ctx(
            method: HttpMethod.get,
            store: store,
            clock: clock,
            config: _config,
          ),
          invite.token,
        ),
      );
      final results = await Future.wait(futures);
      final codes = results.map((r) => r.statusCode).toList();
      expect(
        codes.where((c) => c == HttpStatus.ok).length,
        1,
        reason: 'exactly one fetch must win',
      );
      expect(
        codes.where((c) => c == HttpStatus.gone).length,
        3,
        reason: 'the rest must be 410',
      );
    });

    test('logs do not contain the token or bundle body', () async {
      final logger = Logger.detached('onboarding-test')..level = Level.ALL;
      final captured = <String>[];
      final sub = logger.onRecord
          .listen((r) => captured.add('${r.message} ${r.error ?? ''}'));
      addTearDown(sub.cancel);

      final localStore = InviteStore(
        inviteDir: Directory('${tmp.path}/local-invites'),
        clock: clock,
        logger: logger,
      );
      final invite = await localStore.mint(label: 'agent');

      await route.onRequest(
        _ctx(
          method: HttpMethod.get,
          store: localStore,
          clock: clock,
          config: _config,
        ),
        invite.token,
      );

      final allLogs = captured.join('\n');
      expect(
        allLogs,
        isNot(contains(invite.token)),
        reason: 'logs must not include the token',
      );
      expect(
        allLogs,
        isNot(contains('rn_test_key')),
        reason: 'logs must not include the api key',
      );
    });

    test(
      'response does not include Access-Control-Allow-Credentials',
      () async {
        final invite = await store.mint(label: 'agent');
        final res = await route.onRequest(
          _ctx(
            method: HttpMethod.get,
            store: store,
            clock: clock,
            config: _config,
          ),
          invite.token,
        );
        expect(
          res.headers.keys
              .map((k) => k.toLowerCase())
              .contains('access-control-allow-credentials'),
          isFalse,
        );
      },
    );
  });
}
