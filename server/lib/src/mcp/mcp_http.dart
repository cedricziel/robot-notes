import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Hostnames accepted as loopback origins regardless of scheme port, per
/// the `mcp-server` spec's "Origin header is validated against the public
/// origin" requirement. [Uri.host] normalizes a bracketed IPv6 literal
/// (`[::1]`) down to `::1`, so that is what appears here rather than the
/// bracketed form.
const Set<String> kLoopbackOriginHosts = {'localhost', '127.0.0.1', '::1'};

/// Whether [origin] (an `Origin` header value) is acceptable for a `/mcp`
/// request whose public base URL is [base]: either the exact public
/// origin (scheme, host, port) or an `http` loopback origin at any port.
/// An unparsable [origin] is rejected.
bool isAllowedMcpOrigin(String origin, String base) {
  final parsedOrigin = Uri.tryParse(origin);
  if (parsedOrigin == null) return false;
  final parsedBase = Uri.parse(base);
  if (parsedOrigin.scheme == parsedBase.scheme &&
      parsedOrigin.host == parsedBase.host &&
      parsedOrigin.port == parsedBase.port) {
    return true;
  }
  return parsedOrigin.scheme == 'http' &&
      kLoopbackOriginHosts.contains(parsedOrigin.host);
}

/// The `405 Method Not Allowed` response for any non-`POST` request to
/// `/mcp`, carrying the `Allow: POST` header the spec requires.
Response mcpMethodNotAllowed() => Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      headers: {'Allow': 'POST'},
      body: const {'error': 'method_not_allowed'},
    );

/// The `403 Forbidden` response for a request whose `Origin` header did
/// not pass [isAllowedMcpOrigin].
Response mcpForbidden() => Response.json(
      statusCode: HttpStatus.forbidden,
      body: const {'error': 'forbidden'},
    );

/// The `400 Bad Request` response for a request naming an unsupported
/// `MCP-Protocol-Version`.
Response mcpUnsupportedProtocolVersion() => Response.json(
      statusCode: HttpStatus.badRequest,
      body: const {'error': 'unsupported_protocol_version'},
    );
