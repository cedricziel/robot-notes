import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What a robot-notes server at a given base URL supports, discovered via
/// its OAuth authorization-server metadata document. Never throws — any
/// failure (network, non-200, malformed JSON) is treated as "not
/// supported" rather than an error, since this only gates whether the
/// setup screen offers a "Sign in" option alongside manual key entry.
@immutable
class ServerCapabilities {
  /// Creates a capabilities record.
  const ServerCapabilities({required this.supportsOidcLogin});

  /// A capabilities record with every capability disabled — the safe
  /// fallback when detection fails.
  static const none = ServerCapabilities(supportsOidcLogin: false);

  /// Whether the server advertises `robotnotes_oidc_login_supported`.
  final bool supportsOidcLogin;
}

/// Fetches `<baseUrl>/.well-known/oauth-authorization-server` and reads
/// its capabilities. Any failure resolves to [ServerCapabilities.none]
/// rather than throwing.
Future<ServerCapabilities> fetchServerCapabilities(
  String baseUrl, {
  required http.Client client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final uri = Uri.parse('$baseUrl/.well-known/oauth-authorization-server');
    final response = await client.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      return ServerCapabilities.none;
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return ServerCapabilities.none;
    }
    return ServerCapabilities(
      supportsOidcLogin: decoded['robotnotes_oidc_login_supported'] == true,
    );
  } on Object {
    return ServerCapabilities.none;
  }
}
