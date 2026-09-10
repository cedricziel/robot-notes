import 'package:dart_frog/dart_frog.dart';

/// Thrown by [parseFormBody] when the request's `Content-Type` is not
/// `application/x-www-form-urlencoded`.
class UnsupportedFormContentTypeException implements Exception {
  /// Creates the exception, capturing the offending [contentType].
  const UnsupportedFormContentTypeException(this.contentType);

  /// The rejected `Content-Type` header value, or `null` when the header
  /// was absent.
  final String? contentType;

  @override
  String toString() => 'UnsupportedFormContentTypeException($contentType)';
}

/// Parses [request]'s body as `application/x-www-form-urlencoded` into a
/// `Map<String, String>`. Percent-escapes and `+`-as-space are decoded;
/// when a key repeats, the last occurrence wins.
///
/// The `Content-Type` header (ignoring parameters such as a charset) must
/// be `application/x-www-form-urlencoded`; every other value, including a
/// missing header, throws [UnsupportedFormContentTypeException].
Future<Map<String, String>> parseFormBody(Request request) async {
  final contentType = request.headers['content-type'];
  final mediaType = contentType?.split(';').first.trim().toLowerCase();
  if (mediaType != 'application/x-www-form-urlencoded') {
    throw UnsupportedFormContentTypeException(contentType);
  }
  final body = await request.body();
  return Uri.splitQueryString(body);
}
