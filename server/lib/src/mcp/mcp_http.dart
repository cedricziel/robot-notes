import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:flutter_otel_api/flutter_otel_api.dart';

/// Hostnames accepted as loopback origins regardless of scheme port, per
/// the `mcp-server` spec's "Origin header is validated against the public
/// origin" requirement. [Uri.host] normalizes a bracketed IPv6 literal
/// (`[::1]`) down to `::1`, so that is what appears here rather than the
/// bracketed form.
const Set<String> kLoopbackOriginHosts = {'localhost', '127.0.0.1', '::1'};

/// Hard ceiling on a `/mcp` request body, in bytes. A JSON-RPC message —
/// even a large `tools/call` for `update_note` — has no legitimate reason
/// to approach this; it exists to bound how much of a request the server
/// will buffer in memory before JSON-decoding it, regardless of how large
/// a caller (authenticated or not) claims the body is.
const int kMaxMcpBodyBytes = 1024 * 1024;

/// Whether [origin] (an `Origin` header value) is acceptable for a `/mcp`
/// request: an `http` loopback origin at any port is always accepted, and
/// when [publicUrl] (`Config.publicUrl`) is configured its exact origin
/// (scheme, host, port) is also accepted. An unparsable [origin] is
/// rejected.
///
/// [publicUrl] is deliberately the *configured* origin, never one derived
/// from the request's `Host` header: a server with no configured public
/// URL has no origin it can trust a client-controlled header to name, so
/// a `null` [publicUrl] accepts loopback only. Trusting a Host-derived
/// origin instead would let a DNS-rebinding attacker choose the accepted
/// origin themselves by pointing a hostname they control at the server
/// and browsing to it.
bool isAllowedMcpOrigin(String origin, String? publicUrl) {
  final parsedOrigin = Uri.tryParse(origin);
  if (parsedOrigin == null) return false;
  if (parsedOrigin.scheme == 'http' &&
      kLoopbackOriginHosts.contains(parsedOrigin.host)) {
    return true;
  }
  if (publicUrl == null) return false;
  final parsedPublicUrl = Uri.tryParse(publicUrl);
  if (parsedPublicUrl == null) return false;
  return parsedOrigin.scheme == parsedPublicUrl.scheme &&
      parsedOrigin.host == parsedPublicUrl.host &&
      parsedOrigin.port == parsedPublicUrl.port;
}

/// Tags the current span (see `otelHttpTraceMiddleware`) with why `/mcp`
/// rejected this request, so the reason is visible in tracing without
/// having to capture the response body — the middleware's generic
/// `http.status_code` attribute alone doesn't say which of several
/// possible checks failed. The sole owner of the `mcp.error` attribute
/// key; every rejection path in this file and in `routes/mcp/index.dart`
/// calls this rather than setting the attribute directly.
void annotateMcpError(String code) =>
    Span.current?.setAttribute('mcp.error', code);

/// The `405 Method Not Allowed` response for any non-`POST` request to
/// `/mcp`, carrying the `Allow: POST` header the spec requires.
Response mcpMethodNotAllowed() {
  annotateMcpError('method_not_allowed');
  return Response.json(
    statusCode: HttpStatus.methodNotAllowed,
    headers: {'Allow': 'POST'},
    body: const {'error': 'method_not_allowed'},
  );
}

/// The `403 Forbidden` response for a request whose `Origin` header did
/// not pass [isAllowedMcpOrigin].
Response mcpForbidden() {
  annotateMcpError('forbidden');
  return Response.json(
    statusCode: HttpStatus.forbidden,
    body: const {'error': 'forbidden'},
  );
}

/// The `400 Bad Request` response for a request naming an unsupported
/// `MCP-Protocol-Version`.
Response mcpUnsupportedProtocolVersion() {
  annotateMcpError('unsupported_protocol_version');
  return Response.json(
    statusCode: HttpStatus.badRequest,
    body: const {'error': 'unsupported_protocol_version'},
  );
}

/// The `413 Payload Too Large` response for a request body exceeding
/// [kMaxMcpBodyBytes].
Response mcpPayloadTooLarge() {
  annotateMcpError('payload_too_large');
  return Response.json(
    statusCode: HttpStatus.requestEntityTooLarge,
    body: const {'error': 'payload_too_large'},
  );
}
