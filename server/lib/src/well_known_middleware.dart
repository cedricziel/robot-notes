import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/oauth/oauth_response.dart';
import 'package:server/src/public_url.dart';
import 'package:shared/shared.dart';

const String _protectedResourceMcpPath =
    '${Routes.wellKnownProtectedResource}/mcp';

/// Builds a [Middleware] that answers the three unauthenticated OAuth
/// discovery documents:
///
/// - `GET /.well-known/oauth-protected-resource`
/// - `GET /.well-known/oauth-protected-resource/mcp`
/// - `GET /.well-known/oauth-authorization-server`
///
/// Non-`GET` requests to those exact paths are rejected with 405. Every
/// other path (including other `/.well-known/*` paths) passes through to
/// the rest of the handler chain, so unknown discovery documents 404
/// naturally through the router.
///
/// Must run before `bearerAuth` — these documents are how a client
/// discovers the server before it has any credential — but after the
/// `Config` provider, since the public base URL comes from
/// [publicBaseUrl].
Middleware wellKnownMiddleware() {
  return (handler) {
    return (context) async {
      final request = context.request;
      final path = request.uri.path;

      final isProtectedResource = path == Routes.wellKnownProtectedResource ||
          path == _protectedResourceMcpPath;
      if (isProtectedResource) {
        if (request.method != HttpMethod.get) return _methodNotAllowed();
        final base = publicBaseUrl(context);
        return Response.json(
          headers: kNoStoreHeaders,
          body: protectedResourceMetadata(base),
        );
      }

      if (path == Routes.wellKnownAuthorizationServer) {
        if (request.method != HttpMethod.get) return _methodNotAllowed();
        final base = publicBaseUrl(context);
        return Response.json(
          headers: kNoStoreHeaders,
          body: authorizationServerMetadata(base),
        );
      }

      return handler(context);
    };
  };
}

Response _methodNotAllowed() => Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
