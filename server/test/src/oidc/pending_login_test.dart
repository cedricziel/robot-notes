import 'package:server/src/clock.dart';
import 'package:server/src/oauth/pkce.dart';
import 'package:server/src/oidc/pending_login_store.dart';
import 'package:test/test.dart';

void main() {
  group('PendingLoginStore', () {
    test(
        'start persists a PKCE pair, state, and nonce bound to the '
        'consent request', () {
      final store = PendingLoginStore(
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final pending = store.start(
        consentRequest: const {
          'client_id': 'c1',
          'redirect_uri': 'https://agent.example/callback',
        },
      );

      expect(pending.state, isNotEmpty);
      expect(pending.nonce, isNotEmpty);
      expect(pending.codeVerifier, isNotEmpty);
      expect(
        pending.codeChallenge,
        pkceS256Challenge(pending.codeVerifier),
      );
      expect(pending.consentRequest, {
        'client_id': 'c1',
        'redirect_uri': 'https://agent.example/callback',
      });
    });

    test('two calls to start mint different state, nonce, and verifier', () {
      final store = PendingLoginStore();
      final a = store.start(consentRequest: const {});
      final b = store.start(consentRequest: const {});

      expect(a.state, isNot(b.state));
      expect(a.nonce, isNot(b.nonce));
      expect(a.codeVerifier, isNot(b.codeVerifier));
    });

    test('take returns the pending login for a known, unexpired state', () {
      final store = PendingLoginStore(
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final pending = store.start(consentRequest: const {'a': 'b'});

      final taken = store.take(pending.state);
      expect(taken, isNotNull);
      expect(taken!.state, pending.state);
    });

    test('take is single-use — a second take for the same state fails', () {
      final store = PendingLoginStore(
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final pending = store.start(consentRequest: const {});

      store.take(pending.state);
      expect(store.take(pending.state), isNull);
    });

    test('take returns null for an unknown state', () {
      final store = PendingLoginStore();
      expect(store.take('does-not-exist'), isNull);
    });

    test('take returns null once the 10-minute TTL has elapsed', () {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 10, 1),
      ]);
      final store = PendingLoginStore(clock: clock);
      final pending = store.start(consentRequest: const {});

      expect(store.take(pending.state), isNull);
    });

    test('take still succeeds just before the TTL elapses', () {
      final clock = FixedClock([
        DateTime.utc(2026, 4, 25, 10),
        DateTime.utc(2026, 4, 25, 10, 9, 59),
      ]);
      final store = PendingLoginStore(clock: clock);
      final pending = store.start(consentRequest: const {});

      expect(store.take(pending.state), isNotNull);
    });
  });
}
