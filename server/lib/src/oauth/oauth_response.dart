import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Headers required on every `/oauth/register`, `/oauth/token`, and
/// `/oauth/revoke` response (RFC 6749 §5.1): these bodies carry secrets
/// and SHALL NOT be cached.
const Map<String, String> kNoStoreHeaders = {
  HttpHeaders.cacheControlHeader: 'no-store',
  'Pragma': 'no-cache',
};

/// Builds an RFC 6749 `{ "error": ..., "error_description": ... }` JSON
/// error response — the OAuth error shape, distinct from the app's own
/// `{"error": "<code>", "message": ...}` REST envelope — with the
/// no-store headers, optionally merged with [extraHeaders] (e.g. a
/// `WWW-Authenticate` challenge).
Response oauthError(
  int statusCode,
  String error, {
  String? description,
  Map<String, String>? extraHeaders,
}) {
  return Response.json(
    statusCode: statusCode,
    body: {
      'error': error,
      if (description != null) 'error_description': description,
    },
    headers: {
      ...kNoStoreHeaders,
      if (extraHeaders != null) ...extraHeaders,
    },
  );
}
