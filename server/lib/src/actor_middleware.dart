import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/rest_principal.dart';

const String _xActorHeader = 'x-actor';

/// Builds a middleware that derives an [Actor] and exposes it to handlers
/// via `context.read<Actor>()`.
///
/// OAuth and agent credentials use recorded attribution. The operator and
/// exempt paths use the display-only header, which cannot grant permissions.
Middleware actorIdentity() {
  return (handler) {
    return (context) async {
      final principal = context.read<RestPrincipal>();
      final actor = principal.actor != null
          ? Actor(principal.actor!)
          : Actor.fromHeader(context.request.headers[_xActorHeader]);
      return handler(context.provide<Actor>(() => actor));
    };
  };
}
