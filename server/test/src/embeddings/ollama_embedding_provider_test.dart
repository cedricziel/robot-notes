import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:server/src/embeddings/ollama_embedding_provider.dart';
import 'package:test/test.dart';

void main() {
  group('OllamaEmbeddingProvider', () {
    test(
        'POSTs model+prompt to <baseUrl>/api/embeddings and returns the '
        'embedding array', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'embedding': List<double>.generate(768, (i) => i / 768)}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text',
        client: client,
      );

      final vector = await provider.embed('hello world');

      expect(vector, hasLength(768));
      expect(captured, isNotNull);
      expect(captured!.url.toString(), 'http://localhost:11434/api/embeddings');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['model'], 'nomic-embed-text');
      expect(body['prompt'], 'hello world');
    });

    test(
        'dimensions matches the configured model size (768 for '
        'nomic-embed-text)', () {
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text',
        client: MockClient((_) async => http.Response('', 500)),
      );

      expect(provider.dimensions, 768);
    });

    test('throws EmbeddingProviderException on a network error', () async {
      final client = MockClient((_) => throw Exception('connection refused'));
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text',
        client: client,
      );

      expect(
        () => provider.embed('hello'),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });

    test('throws EmbeddingProviderException on a non-2xx response', () async {
      final client = MockClient((_) async => http.Response('boom', 503));
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text',
        client: client,
      );

      expect(
        () => provider.embed('hello'),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });

    test('dimensions throws StateError for an unknown model', () {
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'unknown-model',
        client: MockClient((_) async => http.Response('', 500)),
      );

      expect(() => provider.dimensions, throwsA(isA<StateError>()));
    });

    test('dimensions resolves a tagged model name via its base name', () {
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text:v1.5',
        client: MockClient((_) async => http.Response('', 500)),
      );

      expect(provider.dimensions, 768);
    });

    test(
        'throws EmbeddingProviderException when the embedding array '
        'contains a non-numeric element', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'embedding': [0.1, null],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text',
        client: client,
      );

      expect(
        () => provider.embed('hello'),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });

    test(
        'throws EmbeddingProviderException when the returned vector length '
        "doesn't match the model's dimensions", () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'embedding': List<double>.generate(10, (i) => i / 10)}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final provider = OllamaEmbeddingProvider(
        baseUrl: 'http://localhost:11434',
        model: 'nomic-embed-text',
        client: client,
      );

      expect(
        () => provider.embed('hello'),
        throwsA(isA<EmbeddingProviderException>()),
      );
    });

    test(
      'throws EmbeddingProviderException when the request times out',
      () async {
        final client = MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(jsonEncode({'embedding': <double>[]}), 200);
        });
        final provider = OllamaEmbeddingProvider(
          baseUrl: 'http://localhost:11434',
          model: 'nomic-embed-text',
          client: client,
          timeout: const Duration(milliseconds: 1),
        );

        expect(
          () => provider.embed('hello'),
          throwsA(isA<EmbeddingProviderException>()),
        );
      },
    );
  });
}
