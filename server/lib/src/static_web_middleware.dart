import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Path prefixes the API owns. Requests matching these short-circuit through
/// the static layer so the existing route + auth pipeline keeps full control
/// of `/notes`, `/search`, `/ws`, `/invites/...`, and `/healthz`.
const _apiPrefixes = <String>{
  '/healthz',
  '/ws',
  '/notes',
  '/search',
  '/invites',
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
///      route pipeline takes over).
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
      if (_isApiPath(path)) {
        return handler(context);
      }

      final candidate = _resolveSafePath(webDir, path);
      if (candidate != null) {
        final file = File(candidate);
        if (file.existsSync()) {
          return _serveFile(file, request.method);
        }
      }

      if (_looksLikeSpaPath(path) && indexFile.existsSync()) {
        return _serveFile(indexFile, request.method);
      }

      return Response(statusCode: HttpStatus.notFound);
    };
  };
}

bool _isApiPath(String path) {
  for (final prefix in _apiPrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) {
      return true;
    }
  }
  return false;
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
