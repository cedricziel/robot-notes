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

/// Thrown by [parseFormBody] when the body is not well-formed
/// `application/x-www-form-urlencoded`: a `%` not followed by two hex
/// digits, or a percent-escape that decodes to invalid UTF-8.
class MalformedFormBodyException implements Exception {
  /// Creates the exception.
  const MalformedFormBodyException();

  @override
  String toString() => 'MalformedFormBodyException()';
}

/// Parses [request]'s body as `application/x-www-form-urlencoded` into a
/// `Map<String, String>`. Percent-escapes and `+`-as-space are decoded;
/// when a key repeats, the last occurrence wins.
///
/// The `Content-Type` header (ignoring parameters such as a charset) must
/// be `application/x-www-form-urlencoded`; every other value, including a
/// missing header, throws [UnsupportedFormContentTypeException]. A
/// malformed percent-escape throws [MalformedFormBodyException] rather
/// than letting `Uri.splitQueryString`'s [ArgumentError] or
/// [FormatException] escape as an uncaught 500.
Future<Map<String, String>> parseFormBody(Request request) async {
  final contentType = request.headers['content-type'];
  final mediaType = contentType?.split(';').first.trim().toLowerCase();
  if (mediaType != 'application/x-www-form-urlencoded') {
    throw UnsupportedFormContentTypeException(contentType);
  }
  final body = await request.body();
  try {
    return Uri.splitQueryString(body);
  } on FormatException {
    throw const MalformedFormBodyException();
  } catch (e) {
    // `Uri.splitQueryString` throws a plain `ArgumentError` (not a
    // `FormatException`) for some malformed percent-escapes (e.g. `%ZZ`),
    // even though the input is untrusted request data rather than a
    // programming mistake; narrow the catch to that case and let anything
    // else propagate.
    if (e is ArgumentError) throw const MalformedFormBodyException();
    rethrow;
  }
}
