import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/config.dart';

/// Resolves the absolute public base URL (`<base>`) used for OAuth
/// metadata, redirects, and invite URLs.
///
/// Precedence: [Config.publicUrl] when configured, otherwise
/// `X-Forwarded-Proto` (falling back to the request scheme, then `http`)
/// combined with the `Host` header (falling back to `localhost`). The
/// result never has a trailing slash.
String publicBaseUrl(RequestContext context) {
  final configured = context.read<Config>().publicUrl;
  if (configured != null) return configured;

  final request = context.request;
  final forwardedProto = request.headers['x-forwarded-proto'];
  final scheme = (forwardedProto != null && forwardedProto.isNotEmpty)
      ? forwardedProto.split(',').first.trim()
      : (request.uri.scheme.isNotEmpty ? request.uri.scheme : 'http');
  final host = request.headers['host'] ?? 'localhost';
  return '$scheme://$host';
}

/// The canonical MCP resource identifier for the given public [base] URL.
String mcpResourceUrl(String base) => '$base/mcp';
