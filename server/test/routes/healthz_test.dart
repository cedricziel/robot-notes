import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../../routes/healthz.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

RequestContext _ctx({required HttpMethod method}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => ctx.request).thenReturn(req);
  return ctx;
}

void main() {
  group('GET /healthz', () {
    test('responds with 200 and {"status":"ok","version":<release>}', () async {
      final response = route.onRequest(_ctx(method: HttpMethod.get));
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], contains('application/json'));
      expect(
        await response.json(),
        {'status': 'ok', 'version': robotNotesVersion},
      );
    });
  });

  group('non-GET /healthz', () {
    test('POST returns 405 with method_not_allowed', () async {
      final response = route.onRequest(_ctx(method: HttpMethod.post));
      expect(response.statusCode, HttpStatus.methodNotAllowed);
      expect(await response.json(), {'error': 'method_not_allowed'});
    });

    test('PUT returns 405', () async {
      final response = route.onRequest(_ctx(method: HttpMethod.put));
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });

    test('DELETE returns 405', () async {
      final response = route.onRequest(_ctx(method: HttpMethod.delete));
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
