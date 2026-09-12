import 'dart:async';

import 'package:server/src/oauth/store_support.dart';
import 'package:test/test.dart';

void main() {
  group('KeyedMutex.run', () {
    test('serializes operations on the same key', () async {
      final mutex = KeyedMutex();
      final order = <int>[];
      final gate = Completer<void>();

      final first = mutex.run('k', () async {
        order.add(1);
        await gate.future;
        order.add(2);
      });
      final second = mutex.run('k', () async {
        order.add(3);
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(order, [1]);
      gate.complete();
      await Future.wait([first, second]);
      expect(order, [1, 2, 3]);
    });

    test('different keys do not wait on each other', () async {
      final mutex = KeyedMutex();
      final gate = Completer<void>();
      final secondDone = Completer<void>();

      unawaited(mutex.run('a', () => gate.future));
      unawaited(mutex.run('b', () async => secondDone.complete()));

      await secondDone.future.timeout(const Duration(seconds: 1));
      gate.complete();
    });

    test('a body throwing does not wedge later runs on the same key', () async {
      final mutex = KeyedMutex();
      await expectLater(
        mutex.run('k', () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(await mutex.run('k', () async => 'ok'), 'ok');
    });

    test('the pending map empties once a run on a key settles', () async {
      final mutex = KeyedMutex();
      await mutex.run('k', () async => 'ok');
      expect(mutex.pendingCount, 0);
    });

    test('the pending map empties even when a run throws', () async {
      final mutex = KeyedMutex();
      await expectLater(
        mutex.run('k', () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(mutex.pendingCount, 0);
    });

    test('the pending map empties after a chain of runs on the same key',
        () async {
      final mutex = KeyedMutex();
      for (var i = 0; i < 5; i++) {
        await mutex.run('k', () async => i);
      }
      expect(mutex.pendingCount, 0);
    });
  });

  group('isSafeStoreKey', () {
    test('accepts a minted-token-shaped key', () {
      expect(isSafeStoreKey('AbC123_-xyz'), isTrue);
    });

    test('accepts a 64-character sha256 hex stem', () {
      expect(isSafeStoreKey('a' * 64), isTrue);
    });

    test('rejects path traversal', () {
      expect(isSafeStoreKey('../x'), isFalse);
      expect(isSafeStoreKey('../../etc/passwd'), isFalse);
    });

    test('rejects a key containing a path separator', () {
      expect(isSafeStoreKey('a/b'), isFalse);
    });

    test('rejects an empty key', () {
      expect(isSafeStoreKey(''), isFalse);
    });

    test('rejects a key over 64 characters', () {
      expect(isSafeStoreKey('a' * 65), isFalse);
    });
  });
}
