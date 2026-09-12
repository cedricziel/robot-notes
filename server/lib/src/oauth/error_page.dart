import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Headers shared by every OAuth-flow HTML response (consent page, error
/// pages): no caching, and a CSP tight enough that a 302 redirect
/// triggered by form submission or a query-string sign-in link is never
/// blocked by `form-action`.
const Map<String, String> kOAuthHtmlHeaders = {
  HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'",
  'X-Frame-Options': 'DENY',
  HttpHeaders.cacheControlHeader: 'no-store',
};

/// A minimal, self-contained HTML error page for an OAuth-flow failure
/// that cannot safely redirect back to a client (unknown client, unknown
/// or expired pending login, ...).
Response oauthErrorPage(
  String message, {
  int statusCode = HttpStatus.badRequest,
}) {
  return Response(
    statusCode: statusCode,
    body: '<!doctype html><html lang="en"><body><p>$message</p></body></html>',
    headers: kOAuthHtmlHeaders,
  );
}
