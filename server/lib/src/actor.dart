import 'package:meta/meta.dart';

/// Display identity attached to a request or WebSocket connection.
///
/// The value is supplied by the client via the `X-Actor` HTTP header (or the
/// `actor` field of the WebSocket auth message) and is **not** authenticated
/// — the bearer key is the only trust boundary. Handlers read it back as
/// `context.read<Actor>().name` and use it to populate lock holders,
/// presence rosters, and `changed` event `by` fields.
@immutable
class Actor {
  /// Creates an actor with the given display [name].
  ///
  /// Callers that derive an actor from untrusted input should prefer
  /// [Actor.fromHeader], which centralises the empty/missing → `"unknown"`
  /// fallback so every code path agrees.
  const Actor(this.name);

  /// Builds an [Actor] from an `X-Actor` header value (or any equivalent
  /// untrusted source). A `null`, empty, or whitespace-only value resolves
  /// to [Actor.unknown]; otherwise the trimmed name is used as-is.
  factory Actor.fromHeader(String? header) {
    if (header == null) return unknown;
    final trimmed = header.trim();
    if (trimmed.isEmpty) return unknown;
    return Actor(trimmed);
  }

  /// The default actor identity used when the client did not supply one.
  static const String unknownName = 'unknown';

  /// Pre-built actor for the default identity. Saves a const allocation in
  /// the hot path and lets tests use `identical(actor, Actor.unknown)`.
  static const Actor unknown = Actor(unknownName);

  /// Free-text display name. May be any non-empty string the client chose.
  final String name;

  @override
  bool operator ==(Object other) => other is Actor && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'Actor($name)';
}
