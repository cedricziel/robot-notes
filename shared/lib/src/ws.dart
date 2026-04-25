import 'package:meta/meta.dart';

import 'errors.dart';

/// Marker base type for every WebSocket envelope flowing across `/ws`.
@immutable
sealed class WsMessage {
  const WsMessage();
  Map<String, dynamic> toJson();
}

/// Client → Server: first message after connect; binds the connection.
final class AuthMsg extends WsMessage {
  const AuthMsg({required this.key, this.actor});

  final String key;
  final String? actor;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'auth',
        'key': key,
        if (actor != null) 'actor': actor,
      };

  factory AuthMsg.fromJson(Map<String, dynamic> json) => AuthMsg(
        key: json['key'] as String,
        actor: json['actor'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is AuthMsg && other.key == key && other.actor == actor;

  @override
  int get hashCode => Object.hash(key, actor);
}

/// Server → Client: confirms a successful auth bind.
final class AuthOkMsg extends WsMessage {
  const AuthOkMsg();

  @override
  Map<String, dynamic> toJson() => {'type': 'auth_ok'};

  factory AuthOkMsg.fromJson(Map<String, dynamic> json) {
    final t = json['type'];
    if (t != 'auth_ok') {
      throw FormatException('Expected type=auth_ok, got $t');
    }
    return const AuthOkMsg();
  }

  @override
  bool operator ==(Object other) => other is AuthOkMsg;

  @override
  int get hashCode => 0xA0;
}

/// Client → Server: subscribe to a note's events (or `*` for all notes).
final class SubscribeMsg extends WsMessage {
  const SubscribeMsg({required this.noteId});

  final String noteId;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'subscribe',
        'note_id': noteId,
      };

  factory SubscribeMsg.fromJson(Map<String, dynamic> json) =>
      SubscribeMsg(noteId: json['note_id'] as String);

  @override
  bool operator ==(Object other) =>
      other is SubscribeMsg && other.noteId == noteId;

  @override
  int get hashCode => Object.hash('subscribe', noteId);
}

/// Client → Server: stop receiving events for the given note id.
final class UnsubscribeMsg extends WsMessage {
  const UnsubscribeMsg({required this.noteId});

  final String noteId;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'unsubscribe',
        'note_id': noteId,
      };

  factory UnsubscribeMsg.fromJson(Map<String, dynamic> json) =>
      UnsubscribeMsg(noteId: json['note_id'] as String);

  @override
  bool operator ==(Object other) =>
      other is UnsubscribeMsg && other.noteId == noteId;

  @override
  int get hashCode => Object.hash('unsubscribe', noteId);
}

/// Server → Client: the set of subscribers for a note has changed.
final class PresenceEvent extends WsMessage {
  const PresenceEvent({required this.noteId, required this.viewers});

  final String noteId;
  final List<String> viewers;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'presence',
        'note_id': noteId,
        'viewers': List<String>.unmodifiable(viewers),
      };

  factory PresenceEvent.fromJson(Map<String, dynamic> json) => PresenceEvent(
        noteId: json['note_id'] as String,
        viewers: (json['viewers'] as List).cast<String>(),
      );

  @override
  bool operator ==(Object other) {
    if (other is! PresenceEvent) return false;
    if (other.noteId != noteId) return false;
    if (other.viewers.length != viewers.length) return false;
    for (var i = 0; i < viewers.length; i++) {
      if (other.viewers[i] != viewers[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(noteId, Object.hashAll(viewers));
}

/// Server → Client: lock state for a note transitioned. `holder` and
/// `expiresAt` are both null when the note is unlocked.
final class LockEvent extends WsMessage {
  const LockEvent({required this.noteId, this.holder, this.expiresAt});

  final String noteId;
  final String? holder;
  final DateTime? expiresAt;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'lock',
        'note_id': noteId,
        'holder': holder,
        'expires_at': expiresAt?.toUtc().toIso8601String(),
      };

  factory LockEvent.fromJson(Map<String, dynamic> json) => LockEvent(
        noteId: json['note_id'] as String,
        holder: json['holder'] as String?,
        expiresAt: json['expires_at'] == null
            ? null
            : DateTime.parse(json['expires_at'] as String).toUtc(),
      );

  @override
  bool operator ==(Object other) =>
      other is LockEvent &&
      other.noteId == noteId &&
      other.holder == holder &&
      ((other.expiresAt == null && expiresAt == null) ||
          (other.expiresAt != null &&
              expiresAt != null &&
              other.expiresAt!.isAtSameMomentAs(expiresAt!)));

  @override
  int get hashCode => Object.hash(noteId, holder, expiresAt?.toUtc());
}

/// Discriminator for `ChangedEvent.action`.
enum ChangeAction {
  created('created'),
  updated('updated'),
  deleted('deleted');

  const ChangeAction(this.wire);
  final String wire;

  static ChangeAction fromWire(String wire) {
    for (final a in ChangeAction.values) {
      if (a.wire == wire) return a;
    }
    throw FormatException('Unknown change action: $wire');
  }
}

/// Server → Client: a note was created, updated, or deleted. Content is NOT
/// shipped — clients HTTP-GET the note to retrieve fresh content.
final class ChangedEvent extends WsMessage {
  const ChangedEvent({
    required this.noteId,
    required this.version,
    required this.by,
    required this.action,
  });

  final String noteId;
  final int? version;
  final String by;
  final ChangeAction action;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'changed',
        'note_id': noteId,
        'version': version,
        'by': by,
        'action': action.wire,
      };

  factory ChangedEvent.fromJson(Map<String, dynamic> json) => ChangedEvent(
        noteId: json['note_id'] as String,
        version: json['version'] as int?,
        by: json['by'] as String,
        action: ChangeAction.fromWire(json['action'] as String),
      );

  @override
  bool operator ==(Object other) =>
      other is ChangedEvent &&
      other.noteId == noteId &&
      other.version == version &&
      other.by == by &&
      other.action == action;

  @override
  int get hashCode => Object.hash(noteId, version, by, action);
}

/// Client → Server: application-layer keepalive request.
final class PingMsg extends WsMessage {
  const PingMsg({required this.id});

  final String id;

  @override
  Map<String, dynamic> toJson() => {'type': 'ping', 'id': id};

  factory PingMsg.fromJson(Map<String, dynamic> json) =>
      PingMsg(id: json['id'] as String);

  @override
  bool operator ==(Object other) => other is PingMsg && other.id == id;

  @override
  int get hashCode => Object.hash('ping', id);
}

/// Server → Client: echo of an inbound `ping`.
final class PongMsg extends WsMessage {
  const PongMsg({required this.id});

  final String id;

  @override
  Map<String, dynamic> toJson() => {'type': 'pong', 'id': id};

  factory PongMsg.fromJson(Map<String, dynamic> json) =>
      PongMsg(id: json['id'] as String);

  @override
  bool operator ==(Object other) => other is PongMsg && other.id == id;

  @override
  int get hashCode => Object.hash('pong', id);
}

/// Server → Client: protocol-level error reply. Does NOT close the connection.
final class ErrorMsg extends WsMessage {
  const ErrorMsg({required this.code, this.received});

  final ErrorCode code;
  final String? received;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'error',
        'error': code.wire,
        if (received != null) 'received': received,
      };

  factory ErrorMsg.fromJson(Map<String, dynamic> json) {
    final wire = json['error'] as String;
    final code = ErrorCode.fromWire(wire);
    if (code == null) {
      throw FormatException('Unknown error code: $wire');
    }
    return ErrorMsg(code: code, received: json['received'] as String?);
  }

  @override
  bool operator ==(Object other) =>
      other is ErrorMsg && other.code == code && other.received == received;

  @override
  int get hashCode => Object.hash(code, received);
}

/// Decodes a parsed JSON map into the appropriate [WsMessage] subtype based on
/// the `type` discriminator. Throws [FormatException] when the type is missing
/// or unrecognized.
WsMessage decodeWsMessage(Map<String, dynamic> json) {
  final type = json['type'];
  if (type is! String) {
    throw const FormatException('WebSocket message missing string "type"');
  }
  switch (type) {
    case 'auth':
      return AuthMsg.fromJson(json);
    case 'auth_ok':
      return AuthOkMsg.fromJson(json);
    case 'subscribe':
      return SubscribeMsg.fromJson(json);
    case 'unsubscribe':
      return UnsubscribeMsg.fromJson(json);
    case 'presence':
      return PresenceEvent.fromJson(json);
    case 'lock':
      return LockEvent.fromJson(json);
    case 'changed':
      return ChangedEvent.fromJson(json);
    case 'ping':
      return PingMsg.fromJson(json);
    case 'pong':
      return PongMsg.fromJson(json);
    case 'error':
      return ErrorMsg.fromJson(json);
    default:
      throw FormatException('Unknown WebSocket message type: $type');
  }
}
