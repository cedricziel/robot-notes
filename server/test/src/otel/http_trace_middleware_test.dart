import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:dart_otel_sdk/dart_otel_sdk.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/otel/http_trace_middleware.dart';
import 'package:shelf/shelf.dart' show HijackException;
import 'package:test/test.dart';

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

class _RecordingProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

/// Bundles a fresh middleware and the processor recording the spans it
/// produces, so each test only states what differs from the others.
({_RecordingProcessor processor, Middleware middleware}) _harness() {
  final processor = _RecordingProcessor();
  final tracer = SdkTracer(name: 'test', version: null, processor: processor);
  return (processor: processor, middleware: otelHttpTraceMiddleware(tracer));
}

RequestContext _ctx({
  HttpMethod method = HttpMethod.get,
  String path = '/notes',
  Map<String, String> headers = const {},
}) {
  final ctx = _MockRequestContext();
  final req = _MockRequest();
  when(() => req.method).thenReturn(method);
  when(() => req.uri).thenReturn(Uri.parse('http://localhost$path'));
  final lower = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  when(() => req.headers).thenReturn(lower);
  when(() => ctx.request).thenReturn(req);
  return ctx;
}

void main() {
  group('otelHttpTraceMiddleware', () {
    test(
      'wraps the handler in a server-kind span with http attributes',
      () async {
        final h = _harness();
        final ctx = _ctx(method: HttpMethod.post);

        final response = await h.middleware(
          (_) async => Response(statusCode: 201),
        )(ctx);

        expect(response.statusCode, 201);
        final data = h.processor.ended.single;
        expect(data.name, 'POST /notes');
        expect(data.kind, SpanKind.server);
        expect(data.attributes['http.method'], 'POST');
        expect(data.attributes['http.target'], '/notes');
        expect(data.attributes['http.route'], '/notes');
        expect(data.attributes['http.status_code'], 201);
        expect(data.statusCode, StatusCode.unset);
      },
    );

    test(
      'captures request and response headers per semconv, redacting secrets',
      () async {
        final h = _harness();
        final ctx = _ctx(
          headers: {
            'Authorization': 'Bearer s3cret',
            'Content-Type': 'application/json',
          },
        );

        await h.middleware(
          (_) async => Response(
            headers: {'X-Request-Id': 'r1', 'Set-Cookie': 'sid=1'},
          ),
        )(ctx);

        final attrs = h.processor.ended.single.attributes;
        expect(attrs['http.request.header.content_type'], [
          'application/json',
        ]);
        expect(attrs['http.request.header.authorization'], ['[REDACTED]']);
        expect(attrs['http.response.header.x_request_id'], ['r1']);
        expect(attrs['http.response.header.set_cookie'], ['[REDACTED]']);
        expect(attrs.toString(), isNot(contains('s3cret')));
      },
    );

    test(
      'normalizes a note ID segment into the span name and http.route',
      () async {
        final h = _harness();
        final ctx = _ctx(path: '/notes/01J8Z9K3QYN8V6R6ZC1E7S4G3M/backlinks');

        await h.middleware((_) async => Response())(ctx);

        final data = h.processor.ended.single;
        expect(data.name, 'GET /notes/:id/backlinks');
        expect(
          data.attributes['http.target'],
          '/notes/01J8Z9K3QYN8V6R6ZC1E7S4G3M/backlinks',
        );
        expect(data.attributes['http.route'], '/notes/:id/backlinks');
      },
    );

    test('normalizes an invite token segment into the span name', () async {
      final h = _harness();
      final ctx = _ctx(path: '/invites/abc123/onboarding.txt');

      await h.middleware((_) async => Response())(ctx);

      final data = h.processor.ended.single;
      expect(data.name, 'GET /invites/:token/onboarding.txt');
    });

    test('sets an error status for a 5xx response', () async {
      final h = _harness();
      final ctx = _ctx();

      await h.middleware(
        (_) async => Response(statusCode: HttpStatus.internalServerError),
      )(ctx);

      final data = h.processor.ended.single;
      expect(data.statusCode, StatusCode.error);
    });

    test(
      'records an unhandled exception, sets an error status, and rethrows',
      () async {
        final h = _harness();
        final ctx = _ctx();

        await expectLater(
          h.middleware((_) async => throw StateError('boom'))(ctx),
          throwsA(isA<StateError>()),
        );

        final data = h.processor.ended.single;
        expect(data.statusCode, StatusCode.error);
        expect(data.events.single.name, 'exception');
      },
    );

    test(
      'rethrows a HijackException without recording it as an error',
      () async {
        final h = _harness();
        final ctx = _ctx();

        await expectLater(
          h.middleware((_) async => throw const HijackException())(ctx),
          throwsA(isA<HijackException>()),
        );

        final data = h.processor.ended.single;
        expect(data.statusCode, isNot(StatusCode.error));
        expect(data.events, isEmpty);
      },
    );

    test('uses an incoming traceparent header as the parent context', () async {
      final h = _harness();
      const traceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const parentSpanId = 'bbbbbbbbbbbbbbbb';
      final ctx = _ctx(
        headers: {'traceparent': '00-$traceId-$parentSpanId-01'},
      );

      await h.middleware((_) async => Response())(ctx);

      final data = h.processor.ended.single;
      expect(data.spanContext.traceId, traceId);
      expect(data.parentSpanId, parentSpanId);
    });

    test('makes the span ambient for the duration of the handler', () async {
      final h = _harness();
      final ctx = _ctx();
      SpanContext? seenDuringHandler;

      await h.middleware((_) async {
        seenDuringHandler = Span.current?.spanContext;
        return Response();
      })(ctx);

      final data = h.processor.ended.single;
      expect(seenDuringHandler, data.spanContext);
    });
  });
}
