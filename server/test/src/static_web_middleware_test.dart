import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/static_web_middleware.dart';
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({
  required String path,
  HttpMethod method = HttpMethod.get,
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('http://localhost$path'));
  when(() => req.headers).thenReturn(const {});
  when(() => ctx.request).thenReturn(req);
  return ctx;
}

Future<Response> _run(
  Middleware mw,
  RequestContext context, {
  Response Function()? handler,
}) async {
  Future<Response> inner(RequestContext _) async =>
      (handler ?? () => Response(body: 'fallthrough'))();
  return mw(inner)(context);
}

Directory _scratchWeb() {
  final dir = Directory.systemTemp.createTempSync('robotnotes_web_');
  File('${dir.path}/index.html').writeAsStringSync('<html>app</html>');
  File('${dir.path}/main.dart.js').writeAsStringSync('console.log("hi");');
  Directory('${dir.path}/assets').createSync();
  File('${dir.path}/assets/AssetManifest.json').writeAsStringSync('{"a":"b"}');
  return dir;
}

void main() {
  group('staticWebMiddleware', () {
    test('null webDir is a no-op (passes through to handler)', () async {
      final ctx = _ctx(path: '/');
      final response = await _run(staticWebMiddleware(), ctx);
      expect(await response.body(), 'fallthrough');
    });

    test('missing webDir is a no-op', () async {
      final ctx = _ctx(path: '/');
      final response = await _run(
        staticWebMiddleware(webDir: '/nonexistent/path/web'),
        ctx,
      );
      expect(await response.body(), 'fallthrough');
    });

    test('serves index.html for GET /', () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/');
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], contains('text/html'));
      expect(await response.body(), '<html>app</html>');
    });

    test('serves an existing static asset with the right Content-Type',
        () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/main.dart.js');
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.headers['content-type'],
        contains('application/javascript'),
      );
      expect(await response.body(), 'console.log("hi");');
    });

    test('serves a nested asset', () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/assets/AssetManifest.json');
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], contains('application/json'));
      expect(await response.body(), '{"a":"b"}');
    });

    test('falls back to index.html for unknown extension-less paths (SPA)',
        () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/some-deep-link');
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.body(), '<html>app</html>');
    });

    test('returns 404 for an asset path with extension that does not exist',
        () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/missing.js');
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    // Real `..` traversal attempts are stripped by `Uri` normalization
    // before they ever reach the middleware, so we can't drive that path
    // through the public contract. The middleware still keeps a
    // defense-in-depth check on `..` segments in [_resolveSafePath].

    test('passes through to handler for /healthz', () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/healthz');
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
        handler: () => Response.json(body: const {'status': 'ok'}),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.json(), {'status': 'ok'});
    });

    test('passes through to handler for /notes and subpaths', () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      for (final path in const ['/notes', '/notes/01ABC', '/notes/01/lock']) {
        final ctx = _ctx(path: path);
        final response = await _run(
          staticWebMiddleware(webDir: dir.path),
          ctx,
          handler: () => Response(body: 'api'),
        );
        expect(await response.body(), 'api', reason: 'path=$path');
      }
    });

    test('passes through to handler for /search, /ws, /invites', () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      for (final path in const ['/search', '/ws', '/invites/abc']) {
        final ctx = _ctx(path: path);
        final response = await _run(
          staticWebMiddleware(webDir: dir.path),
          ctx,
          handler: () => Response(body: 'api'),
        );
        expect(await response.body(), 'api', reason: 'path=$path');
      }
    });

    test('non-GET non-HEAD requests pass through to handler', () async {
      final dir = _scratchWeb();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ctx = _ctx(path: '/', method: HttpMethod.post);
      final response = await _run(
        staticWebMiddleware(webDir: dir.path),
        ctx,
        handler: () => Response(body: 'api'),
      );
      expect(await response.body(), 'api');
    });
  });
}
