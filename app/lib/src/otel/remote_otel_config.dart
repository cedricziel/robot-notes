import 'dart:convert';

import 'package:http/http.dart' as http;

import 'otel_build_config.dart';

/// Fetches the connected server's runtime OTel export config from
/// `{baseUrl}/otel-config` (see `server/routes/otel-config.dart`).
///
/// This is how the app and the web bundle enable telemetry: at runtime, by
/// asking the server they are already talking to, rather than baking an
/// operator's endpoint/key into the distributed app at build time. Never
/// throws — any network failure, non-200 response, or malformed body
/// resolves to a disabled [OtelBuildConfig] so a telemetry hiccup can never
/// break the app.
Future<OtelBuildConfig> fetchRemoteOtelConfig(
  String baseUrl, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final response = await client.get(Uri.parse('$baseUrl/otel-config'));
    if (response.statusCode != 200) return const OtelBuildConfig();

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['enabled'] != true) {
      return const OtelBuildConfig();
    }

    final rawEndpoint = decoded['endpoint'];
    if (rawEndpoint is! String) return const OtelBuildConfig();
    final endpoint = Uri.tryParse(rawEndpoint);
    final validEndpoint =
        endpoint != null &&
        (endpoint.scheme == 'http' || endpoint.scheme == 'https') &&
        endpoint.host.isNotEmpty;
    if (!validEndpoint) return const OtelBuildConfig();

    final headers = <String, String>{};
    final rawHeaders = decoded['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }

    return OtelBuildConfig(endpoint: endpoint, headers: headers);
  } catch (_) {
    return const OtelBuildConfig();
  } finally {
    if (httpClient == null) client.close();
  }
}
