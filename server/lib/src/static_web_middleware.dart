import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:shared/shared.dart';

/// Path prefixes that are unambiguously the API's — never reachable as a
/// client-side route — so they short-circuit through the static layer
/// regardless of `Authorization`.
const _alwaysApiPrefixes = <String>{
  Routes.healthz,
  Routes.otelConfig,
  Routes.ws,
  Routes.invites,
  Routes.mcp,
  Routes.tags,
  '/oauth',
  '/.well-known',
};

/// MIME table covering everything `flutter build web` ships, plus a few
/// extras for forward-compatibility. Anything unmapped is served as
/// `application/octet-stream`.
const _mimeTypes = <String, String>{
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.wasm': 'application/wasm',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
};

/// Builds a [Middleware] that serves the Flutter web bundle living under
/// [webDir] at the root of the HTTP server.
///
/// Resolution order for an incoming `GET` (or `HEAD`):
///   1. If [webDir] is `null` or does not exist on disk → no-op pass-through.
///   2. If the path matches a known API prefix → pass-through (the auth +
///      route pipeline takes over, so a missing/malformed/mismatched key
///      still gets the documented 401). `/notes/{id}` and `/search` count
///      as the app's own client-side routes — not API paths — only when the
///      request has no `Authorization` header *and* its `Accept` header
///      names `text/html`, the signature of a plain browser navigation
///      (reload, bookmark, shared link). Any other request to those paths,
///      including one with no `Authorization` at all, stays on the API
///      pipeline. Either way, the response carries `Vary: Accept,
///      Authorization` and a `Cache-Control` matching the branch served
///      (`no-cache` for the SPA, `no-store` for the API) so a cache can't
///      replay one representation in place of the other.
///   3. If `<webDir>/<path>` exists → serve it with the inferred MIME type.
///   4. If the path looks like an SPA route (no file extension) → fall
///      back to `<webDir>/index.html`.
///   5. Otherwise → `404`.
///
/// Path traversal (`..` segments) is rejected with `404` regardless of
/// what is on disk.
///
/// The middleware short-circuits before `bearerAuth` runs, so the bundle
/// itself is unauthenticated. The bundle never contains secrets — the
/// user supplies the API key at runtime through the setup screen.
Middleware staticWebMiddleware({String? webDir}) {
  if (webDir == null || webDir.isEmpty) {
    return (handler) => handler;
  }
  final root = Directory(webDir);
  if (!root.existsSync()) {
    return (handler) => handler;
  }
  final indexFile = File('$webDir/index.html');

  return (handler) {
    return (context) async {
      final request = context.request;
      if (request.method != HttpMethod.get &&
          request.method != HttpMethod.head) {
        return handler(context);
      }
      final path = request.uri.path;
      final isDualUsePath = _isDualUsePath(path);
      if (_isApiPath(request)) {
        final response = await handler(context);
        // `/notes/{id}` and `/search` serve different bodies (HTML vs JSON)
        // from the same URL depending on `Accept`/`Authorization`; without
        // `Vary`, a cache (including the browser's own bfcache) can replay
        // one representation for a request that should get the other — this
        // is what let a back-navigation render raw JSON after a hard reload.
        return isDualUsePath
            ? _withDualUseHeaders(response, api: true)
            : response;
      }

      final candidate = _resolveSafePath(webDir, path);
      if (candidate != null) {
        final file = File(candidate);
        if (file.existsSync()) {
          final response = _serveFile(file, request.method);
          return isDualUsePath
              ? _withDualUseHeaders(response, api: false)
              : response;
        }
      }

      if (_looksLikeSpaPath(path) && indexFile.existsSync()) {
        final response = _serveFile(indexFile, request.method);
        return isDualUsePath
            ? _withDualUseHeaders(response, api: false)
            : response;
      }

      return Response(statusCode: HttpStatus.notFound);
    };
  };
}

bool _isApiPath(Request request) {
  final path = request.uri.path;
  for (final prefix in _alwaysApiPrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) {
      return true;
    }
  }
  // Bare `GET /notes` (the list endpoint) isn't one of the app's routes, so
  // it stays API-only regardless of `Authorization`.
  if (path == Routes.notes) return true;

  // `/notes/{id}` and `/search` are *also* client-side routes in the
  // Flutter app (the note view and the search screen), reached by a plain
  // browser navigation — reload, bookmark, or a shared link — at the same
  // path as the API call of the same name. Treat a request here as that
  // browser navigation, rather than an API call, only when it has neither
  // signal an API client sends: no `Authorization` header *and* an `Accept`
  // header naming `text/html` (what a browser sends on navigation; the
  // app's own HTTP client, curl, and MCP/agent clients don't ask for
  // `text/html`). Anything else — including a request with no
  // `Authorization` at all but an `Accept` the app wouldn't send — stays on
  // the API pipeline and gets the documented 401, not HTML.
  if (_isDualUsePath(path)) {
    final hasBearerAuth =
        extractBearerToken(request.headers['authorization']) != null;
    final looksLikeBrowserNavigation = !hasBearerAuth && _acceptsHtml(request);
    return !looksLikeBrowserNavigation;
  }
  return false;
}

/// `/notes/{id}` and `/search` — not bare `/notes` — serve both the SPA and
/// the JSON API at the same URL; see [_isApiPath].
bool _isDualUsePath(String path) =>
    path == Routes.search || path.startsWith('${Routes.notes}/');

bool _acceptsHtml(Request request) {
  final accept = request.headers['accept'];
  return accept != null && accept.contains('text/html');
}

/// Adds `Vary: Accept, Authorization` (merged with any existing `Vary`) so a
/// cache never serves one representation of a dual-use path in place of the
/// other — the browser's own bfcache doing exactly that, on a back
/// navigation, is what motivated this. The SPA branch also gets a
/// must-revalidate `Cache-Control` so deploys take effect immediately; the
/// API branch gets `no-store` since note content is private, per-key data.
Response _withDualUseHeaders(Response response, {required bool api}) {
  final existingVary = response.headers['vary'];
  final vary = [
    if (existingVary != null && existingVary.isNotEmpty) existingVary,
    'Accept',
    'Authorization',
  ].join(', ');
  return response.copyWith(
    headers: {
      ...response.headers,
      'vary': vary,
      'cache-control': api ? 'no-store' : 'no-cache',
    },
  );
}

/// Joins [requestPath] onto [root], rejecting traversal. `/` resolves to
/// `<root>/index.html`. Returns `null` for paths that try to escape [root].
String? _resolveSafePath(String root, String requestPath) {
  final relative = requestPath.replaceFirst(RegExp('^/+'), '');
  if (relative.isEmpty) {
    return '$root/index.html';
  }
  // Cheap guard against `..` and absolute components in any segment.
  for (final segment in relative.split('/')) {
    if (segment == '..' || segment.isEmpty) return null;
  }
  return '$root/$relative';
}

bool _looksLikeSpaPath(String path) {
  final lastSegment = path.split('/').last;
  return !lastSegment.contains('.');
}

Response _serveFile(File file, HttpMethod method) {
  final dotIdx = file.path.lastIndexOf('.');
  final ext = dotIdx == -1 ? '' : file.path.substring(dotIdx);
  final contentType = _mimeTypes[ext] ?? 'application/octet-stream';

  if (method == HttpMethod.head) {
    return Response(
      headers: {
        'content-type': contentType,
        'content-length': '${file.lengthSync()}',
      },
    );
  }
  return Response.bytes(
    body: file.readAsBytesSync(),
    headers: {'content-type': contentType},
  );
}
