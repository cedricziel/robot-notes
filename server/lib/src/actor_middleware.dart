import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';

const String _xActorHeader = 'x-actor';

/// Builds a middleware that derives an [Actor] from the incoming `X-Actor`
/// header and exposes it to handlers via `context.read<Actor>()`.
///
/// The header is treated as untrusted display-only metadata: a `null`,
/// empty, or whitespace-only value resolves to [Actor.unknown]. Handlers
/// SHOULD consume the actor through `context.read<Actor>()` rather than
/// re-parsing the header so the fallback rule stays consistent.
Middleware actorIdentity() {
  return (handler) {
    return (context) async {
      final actor = Actor.fromHeader(context.request.headers[_xActorHeader]);
      return handler(context.provide<Actor>(() => actor));
    };
  };
}
