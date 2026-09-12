import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/auth_middleware.dart' show extractBearerToken;
import 'package:server/src/config.dart';
import 'package:server/src/constant_time.dart';
import 'package:server/src/mcp/principal.dart';
import 'package:server/src/oauth/token_store.dart';
import 'package:server/src/public_url.dart';
import 'package:shared/shared.dart';

const String _protectedResourceMcpPath =
    '${Routes.wellKnownProtectedResource}/mcp';

/// Builds the `/mcp`-only auth [Middleware]: accepts either the configured
/// static API key or a valid OAuth access token bound to this server's MCP
/// resource, and provides an [McpPrincipal] to the route handler.
///
/// Only the `Authorization` header is consulted — never a query-string
/// parameter — per the `mcp-server` spec's "Access tokens SHALL NOT be
/// accepted from the query string" rule.
///
/// Failure is always HTTP 401 with the JSON envelope
/// `{"error":"unauthorized"}` and a `WWW-Authenticate` header naming the
/// protected-resource metadata document, so a client that has never
/// connected before can discover how to obtain a credential. When a
/// credential was supplied but rejected, the header additionally carries
/// `error="invalid_token"` so a client can distinguish "no credential yet"
/// from "this credential is dead".
Middleware mcpAuth() {
  return (handler) {
    return (context) async {
      final supplied =
          extractBearerToken(context.request.headers['authorization']);
      if (supplied == null) {
        return _unauthorized(context, credentialSupplied: false);
      }

      final config = context.read<Config>();
      if (constantTimeEquals(config.apiKey, supplied)) {
        final actor = context.read<Actor>().name;
        return handler(
          context.provide<McpPrincipal>(() => McpPrincipal.staticKey(actor)),
        );
      }

      final tokenStore = context.read<TokenStore>();
      final record = await tokenStore.lookupAccess(supplied);
      final resource = mcpResourceUrl(publicBaseUrl(context));
      if (record == null || record.resource != resource) {
        return _unauthorized(context, credentialSupplied: true);
      }

      final principal = McpPrincipal(
        actor: record.actor,
        scopes: record.scopes,
        isStaticKey: false,
      );
      return handler(context.provide<McpPrincipal>(() => principal));
    };
  };
}

Response _unauthorized(
  RequestContext context, {
  required bool credentialSupplied,
}) {
  final resourceMetadata =
      '${publicBaseUrl(context)}$_protectedResourceMcpPath';
  final challenge = StringBuffer(
    'Bearer realm="robot-notes", resource_metadata="$resourceMetadata"',
  );
  if (credentialSupplied) {
    challenge.write(', error="invalid_token"');
  }
  return Response.json(
    statusCode: HttpStatus.unauthorized,
    headers: {'WWW-Authenticate': challenge.toString()},
    body: const {'error': 'unauthorized'},
  );
}
