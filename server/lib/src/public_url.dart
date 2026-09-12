import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/config.dart';
import 'package:shared/shared.dart';

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
  final forwardedProto = _firstForwardedProto(
    request.headers['x-forwarded-proto'],
  );
  final scheme = forwardedProto ??
      (request.uri.scheme.isNotEmpty ? request.uri.scheme : 'http');
  final host = request.headers['host'] ?? 'localhost';
  return '$scheme://$host';
}

/// The canonical MCP resource identifier for the given public [base] URL.
String mcpResourceUrl(String base) => '$base${Routes.mcp}';

/// Parses the first comma-separated value of an `X-Forwarded-Proto` header
/// as a scheme, returning it only when it is exactly `http` or `https`
/// (case-insensitively, surrounding whitespace trimmed); `null` otherwise
/// (including a `null` or empty [header]), so a reverse proxy that forwards
/// an unexpected or attacker-controlled value can never inject anything
/// beyond those two schemes into the derived base URL.
String? _firstForwardedProto(String? header) {
  if (header == null || header.isEmpty) return null;
  final candidate = header.split(',').first.trim().toLowerCase();
  return candidate == 'http' || candidate == 'https' ? candidate : null;
}

/// Operator warning logged at startup when no public URL is configured,
/// since the OAuth issuer and resource are then derived from request
/// headers. `null` when [Config.publicUrl] is set.
String? publicUrlStartupWarning(Config config) {
  if (config.publicUrl != null) return null;
  return 'No public URL configured; the OAuth issuer and MCP resource are '
      'derived from the Host and X-Forwarded-Proto headers of each request. '
      'Set --public-url or ROBOT_NOTES_PUBLIC_URL for any deployment that '
      'is not loopback-only.';
}
