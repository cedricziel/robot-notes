import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('AuthMsg', () {
    test('round-trips with actor', () {
      final msg = AuthMsg(key: 'rn_secret', actor: 'alice');
      expect(msg.toJson(), {
        'type': 'auth',
        'key': 'rn_secret',
        'actor': 'alice',
      });
      expect(AuthMsg.fromJson(msg.toJson()), equals(msg));
    });

    test('omits actor when null', () {
      final msg = AuthMsg(key: 'rn_secret');
      expect(msg.toJson(), {'type': 'auth', 'key': 'rn_secret'});
      expect(AuthMsg.fromJson(msg.toJson()).actor, isNull);
    });
  });

  group('AuthOkMsg', () {
    test('serializes the auth_ok envelope', () {
      expect(AuthOkMsg().toJson(), {'type': 'auth_ok'});
      expect(AuthOkMsg.fromJson({'type': 'auth_ok'}), equals(AuthOkMsg()));
    });
  });

  group('SubscribeMsg / UnsubscribeMsg', () {
    test('subscribe carries note_id', () {
      final msg = SubscribeMsg(noteId: 'X');
      expect(msg.toJson(), {'type': 'subscribe', 'note_id': 'X'});
      expect(SubscribeMsg.fromJson(msg.toJson()), equals(msg));
    });

    test('subscribe accepts wildcard', () {
      final msg = SubscribeMsg(noteId: '*');
      expect(msg.toJson()['note_id'], '*');
    });

    test('unsubscribe carries note_id', () {
      final msg = UnsubscribeMsg(noteId: 'X');
      expect(msg.toJson(), {'type': 'unsubscribe', 'note_id': 'X'});
      expect(UnsubscribeMsg.fromJson(msg.toJson()), equals(msg));
    });
  });

  group('PresenceEvent', () {
    test('round-trips with viewers', () {
      final evt = PresenceEvent(noteId: 'X', viewers: ['alice', 'bob']);
      expect(evt.toJson(), {
        'type': 'presence',
        'note_id': 'X',
        'viewers': ['alice', 'bob'],
      });
      expect(PresenceEvent.fromJson(evt.toJson()), equals(evt));
    });
  });

  group('LockEvent', () {
    test('held lock includes holder and expires_at', () {
      final evt = LockEvent(
        noteId: 'X',
        holder: 'alice',
        expiresAt: DateTime.utc(2026, 4, 25, 12, 0),
      );
      final json = evt.toJson();
      expect(json['type'], 'lock');
      expect(json['note_id'], 'X');
      expect(json['holder'], 'alice');
      expect(json['expires_at'], '2026-04-25T12:00:00.000Z');
      expect(LockEvent.fromJson(json), equals(evt));
    });

    test('released lock has null holder and expires_at', () {
      final evt = LockEvent(noteId: 'X');
      final json = evt.toJson();
      expect(json, {
        'type': 'lock',
        'note_id': 'X',
        'holder': null,
        'expires_at': null,
      });
      expect(LockEvent.fromJson(json), equals(evt));
    });
  });

  group('ChangedEvent', () {
    test('updated event carries version and actor', () {
      final evt = ChangedEvent(
        noteId: 'X',
        version: 6,
        by: 'alice',
        action: ChangeAction.updated,
      );
      expect(evt.toJson(), {
        'type': 'changed',
        'note_id': 'X',
        'version': 6,
        'by': 'alice',
        'action': 'updated',
      });
      expect(ChangedEvent.fromJson(evt.toJson()), equals(evt));
    });

    test('deleted event has null version', () {
      final evt = ChangedEvent(
        noteId: 'X',
        version: null,
        by: 'alice',
        action: ChangeAction.deleted,
      );
      final json = evt.toJson();
      expect(json['version'], isNull);
      expect(json['action'], 'deleted');
      expect(ChangedEvent.fromJson(json), equals(evt));
    });

    test('created event has version 1 and action created', () {
      final evt = ChangedEvent(
        noteId: 'X',
        version: 1,
        by: 'alice',
        action: ChangeAction.created,
      );
      expect(evt.toJson()['action'], 'created');
      expect(ChangedEvent.fromJson(evt.toJson()), equals(evt));
    });
  });

  group('PingMsg / PongMsg', () {
    test('ping carries opaque id', () {
      final msg = PingMsg(id: 'abc');
      expect(msg.toJson(), {'type': 'ping', 'id': 'abc'});
      expect(PingMsg.fromJson(msg.toJson()), equals(msg));
    });

    test('pong echoes id', () {
      final msg = PongMsg(id: 'abc');
      expect(msg.toJson(), {'type': 'pong', 'id': 'abc'});
      expect(PongMsg.fromJson(msg.toJson()), equals(msg));
    });
  });

  group('ErrorMsg', () {
    test('round-trips with received field', () {
      final msg = ErrorMsg(code: ErrorCode.unknownType, received: 'explode');
      expect(msg.toJson(), {
        'type': 'error',
        'error': 'unknown_type',
        'received': 'explode',
      });
      expect(ErrorMsg.fromJson(msg.toJson()), equals(msg));
    });

    test('omits received when null', () {
      final msg = ErrorMsg(code: ErrorCode.unauthorized);
      expect(msg.toJson(), {'type': 'error', 'error': 'unauthorized'});
      expect(ErrorMsg.fromJson(msg.toJson()).received, isNull);
    });
  });

  group('decodeWsMessage', () {
    test('routes by type discriminator', () {
      expect(
        decodeWsMessage({'type': 'auth_ok'}),
        isA<AuthOkMsg>(),
      );
      expect(
        decodeWsMessage({'type': 'subscribe', 'note_id': 'X'}),
        isA<SubscribeMsg>(),
      );
      expect(
        decodeWsMessage({'type': 'pong', 'id': 'k'}),
        isA<PongMsg>(),
      );
    });

    test('throws FormatException on unknown type', () {
      expect(
        () => decodeWsMessage({'type': 'mystery'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when type missing', () {
      expect(
        () => decodeWsMessage({}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
