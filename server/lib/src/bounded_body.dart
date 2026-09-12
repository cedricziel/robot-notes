import 'package:dart_frog/dart_frog.dart';

/// Buffers [request]'s body, giving up as soon as it exceeds [maxBytes].
///
/// Returns `null` when the cap is crossed so callers can reject the request
/// without ever holding more than `maxBytes + one chunk` in memory. Reading
/// the stream rather than `request.body()` matters for chunked uploads that
/// carry no `Content-Length`.
Future<List<int>?> readBoundedBody(
  Request request, {
  required int maxBytes,
}) async {
  final bytes = <int>[];
  await for (final chunk in request.bytes()) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) return null;
  }
  return bytes;
}
