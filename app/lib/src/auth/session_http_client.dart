import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Retries authenticated requests once after renewing rejected credentials.
class SessionHttpClient extends http.BaseClient {
  SessionHttpClient({
    required this.inner,
    required this.config,
    required this.renew,
    required this.onExpired,
  });

  final http.Client inner;
  final AppConfig Function() config;
  final Future<AppConfig?> Function(String rejectedToken) renew;
  final void Function() onExpired;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    Future<http.StreamedResponse> attempt(AppConfig current) {
      final copy = http.Request(request.method, request.url)
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..headers.addAll(request.headers)
        ..headers['Authorization'] = 'Bearer ${current.apiKey}'
        ..bodyBytes = body;
      return inner.send(copy);
    }

    final original = config();
    var response = await attempt(original);
    if (response.statusCode != 401 || _closed) return response;
    if (!original.isOidcSession) {
      onExpired();
      return response;
    }
    await response.stream.drain<void>();
    final refreshed = await renew(original.apiKey);
    if (refreshed == null || _closed) {
      return http.StreamedResponse(const Stream.empty(), 401);
    }
    response = await attempt(refreshed);
    if (response.statusCode == 401 && !_closed) onExpired();
    return response;
  }

  @override
  void close() {
    _closed = true;
    inner.close();
  }
}
