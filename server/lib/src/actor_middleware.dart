import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/rest_principal.dart';

const String _xActorHeader = 'x-actor';

/// Builds a middleware that derives an [Actor] and exposes it to handlers
/// via `context.read<Actor>()`.
///
/// For a request authenticated with an OAuth access token (per the
/// [RestPrincipal] `bearerAuth` (`lib/src/auth_middleware.dart`) provides),
/// the actor is the grant's recorded, cryptographically-backed identity —
/// the untrusted `X-Actor` header is ignored in that case. Otherwise (the
/// static key, or an exempt path) the actor comes from the incoming
/// `X-Actor` header: a `null`, empty, or whitespace-only value resolves to
/// [Actor.unknown].
Middleware actorIdentity() {
  return (handler) {
    return (context) async {
      final principal = context.read<RestPrincipal>();
      final actor = principal.kind == RestAuthKind.oauthToken
          ? Actor(principal.actor!)
          : Actor.fromHeader(context.request.headers[_xActorHeader]);
      return handler(context.provide<Actor>(() => actor));
    };
  };
}
