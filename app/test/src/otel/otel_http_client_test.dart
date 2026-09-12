import 'package:app/src/otel/otel_http_client.dart';
import 'package:flutter_otel/flutter_otel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

/// Bundles a fresh [TracingHttpClient] and the processor recording the
/// spans its tracer produces, so each test only states what differs.
({_RecordingProcessor processor, TracingHttpClient client}) _harness(
  http.Client inner,
) {
  final processor = _RecordingProcessor();
  final tracer = SdkTracer(name: 'test', version: null, processor: processor);
  return (
    processor: processor,
    client: TracingHttpClient(inner, tracerProvider: () => tracer),
  );
}

void main() {
  group('TracingHttpClient', () {
    test('starts a client-kind span with http attributes', () async {
      final h = _harness(MockClient((_) async => http.Response('', 200)));

      await h.client.get(Uri.parse('https://notes.example.com/notes'));

      final data = h.processor.ended.single;
      expect(data.name, 'GET /notes');
      expect(data.kind, SpanKind.client);
      expect(data.attributes['http.method'], 'GET');
      expect(data.attributes['http.target'], '/notes');
      expect(data.attributes['http.status_code'], 200);
      expect(data.statusCode, StatusCode.unset);
    });

    test('normalizes a note ID segment into the span name', () async {
      final h = _harness(MockClient((_) async => http.Response('', 200)));

      await h.client.get(
        Uri.parse(
          'https://notes.example.com/notes/01J8Z9K3QYN8V6R6ZC1E7S4G3M/backlinks',
        ),
      );

      final data = h.processor.ended.single;
      expect(data.name, 'GET /notes/:id/backlinks');
      expect(
        data.attributes['http.target'],
        '/notes/01J8Z9K3QYN8V6R6ZC1E7S4G3M/backlinks',
      );
    });

    test(
      'injects a traceparent header derived from the span context',
      () async {
        http.Request? captured;
        final h = _harness(
          MockClient((request) async {
            captured = request;
            return http.Response('', 200);
          }),
        );

        await h.client.get(Uri.parse('https://notes.example.com/notes'));

        final data = h.processor.ended.single;
        expect(
          captured?.headers['traceparent'],
          formatTraceparent(data.spanContext),
        );
      },
    );

    test('sets an error status for a 5xx response', () async {
      final h = _harness(MockClient((_) async => http.Response('', 503)));

      await h.client.get(Uri.parse('https://notes.example.com/notes'));

      final data = h.processor.ended.single;
      expect(data.attributes['http.status_code'], 503);
      expect(data.statusCode, StatusCode.error);
    });

    test(
      'records an unhandled exception, sets error status, and rethrows',
      () async {
        final h = _harness(
          MockClient((_) async => throw Exception('network down')),
        );

        await expectLater(
          h.client.get(Uri.parse('https://notes.example.com/notes')),
          throwsA(isA<Exception>()),
        );

        final data = h.processor.ended.single;
        expect(data.statusCode, StatusCode.error);
        expect(data.events.single.name, 'exception');
      },
    );
  });
}
