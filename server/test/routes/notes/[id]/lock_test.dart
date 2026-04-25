import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/lock_manager.dart';
import 'package:test/test.dart';

import '../../../../routes/notes/[id]/lock.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required HttpMethod method,
  required LockManager lockManager,
  Actor actor = const Actor('alice'),
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('/notes/x/lock'));
  when(() => ctx.request).thenReturn(req);
  when(() => ctx.read<LockManager>()).thenReturn(lockManager);
  when(() => ctx.read<Actor>()).thenReturn(actor);
  return ctx;
}

void main() {
  late LockManager lockManager;

  setUp(() {
    lockManager = LockManager(
      clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
    );
  });

  tearDown(() async {
    await lockManager.close();
  });

  group('POST /notes/{id}/lock', () {
    test('on unlocked note returns 200 with holder and expiry', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.post, lockManager: lockManager),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['holder'], 'alice');
      expect(body['expires_at'], isA<String>());
    });

    test('blocked by another actor returns 423 with current lock', () async {
      await lockManager.acquire(noteId: 'note-1', actor: 'alice');
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.post,
          lockManager: lockManager,
          actor: const Actor('bob'),
        ),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.locked);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'locked');
      final lock = body['lock'] as Map<String, dynamic>;
      expect(lock['holder'], 'alice');
      expect(lock['expires_at'], isA<String>());
    });

    test('by same actor extends TTL (idempotent 200)', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 0, 30),
        DateTime.utc(2026, 4, 25, 10, 0, 30),
      ]);
      final lm = LockManager(clock: clock);
      addTearDown(lm.close);
      await lm.acquire(noteId: 'note-1', actor: 'alice');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.post, lockManager: lm),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['holder'], 'alice');
      // 30s after T0 + 60s TTL = T0 + 90s
      expect(
        body['expires_at'],
        DateTime.utc(2026, 4, 25, 10, 1, 30).toIso8601String(),
      );
    });
  });

  group('PUT /notes/{id}/lock', () {
    test('heartbeat by holder returns 200 with extended expiry', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 0, 30),
        DateTime.utc(2026, 4, 25, 10, 0, 30),
      ]);
      final lm = LockManager(clock: clock);
      addTearDown(lm.close);
      await lm.acquire(noteId: 'note-1', actor: 'alice');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.put, lockManager: lm),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.ok);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['holder'], 'alice');
      expect(
        body['expires_at'],
        DateTime.utc(2026, 4, 25, 10, 1, 30).toIso8601String(),
      );
    });

    test('heartbeat by non-holder returns 423', () async {
      await lockManager.acquire(noteId: 'note-1', actor: 'alice');
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.put,
          lockManager: lockManager,
          actor: const Actor('bob'),
        ),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.locked);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'locked');
      expect((body['lock'] as Map<String, dynamic>)['holder'], 'alice');
    });

    test('heartbeat on expired lock returns 404 lock_not_found', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 5), // 5min later → past 60s TTL
      ]);
      final lm = LockManager(clock: clock);
      addTearDown(lm.close);
      await lm.acquire(noteId: 'note-1', actor: 'alice');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.put, lockManager: lm),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'lock_not_found');
    });

    test('heartbeat on never-locked note returns 404 lock_not_found', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.put, lockManager: lockManager),
        'note-virgin',
      );
      expect(res.statusCode, HttpStatus.notFound);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'lock_not_found');
    });
  });

  group('DELETE /notes/{id}/lock', () {
    test('release by holder returns 204', () async {
      await lockManager.acquire(noteId: 'note-1', actor: 'alice');
      final res = await route.onRequest(
        _ctx(method: HttpMethod.delete, lockManager: lockManager),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.noContent);
      expect(lockManager.lockOf('note-1'), isNull);
    });

    test('release by non-holder returns 423', () async {
      await lockManager.acquire(noteId: 'note-1', actor: 'alice');
      final res = await route.onRequest(
        _ctx(
          method: HttpMethod.delete,
          lockManager: lockManager,
          actor: const Actor('bob'),
        ),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.locked);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'locked');
      // Lock is still held by alice afterwards.
      expect(lockManager.lockOf('note-1')?.holder, 'alice');
    });

    test('release of missing lock returns 204 (idempotent)', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.delete, lockManager: lockManager),
        'note-virgin',
      );
      expect(res.statusCode, HttpStatus.noContent);
    });

    test('release of expired lock returns 204 (idempotent)', () async {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 5),
      ]);
      final lm = LockManager(clock: clock);
      addTearDown(lm.close);
      await lm.acquire(noteId: 'note-1', actor: 'alice');

      final res = await route.onRequest(
        _ctx(method: HttpMethod.delete, lockManager: lm),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.noContent);
    });
  });

  group('disallowed methods', () {
    test('GET returns 405 method_not_allowed', () async {
      final res = await route.onRequest(
        _ctx(method: HttpMethod.get, lockManager: lockManager),
        'note-1',
      );
      expect(res.statusCode, HttpStatus.methodNotAllowed);
      final body = await res.json() as Map<String, dynamic>;
      expect(body['error'], 'method_not_allowed');
    });
  });
}
