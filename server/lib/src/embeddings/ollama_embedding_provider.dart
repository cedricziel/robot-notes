import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:server/src/embeddings/embedding_provider.dart';

/// [EmbeddingProvider] backed by a local Ollama instance's
/// `/api/embeddings` endpoint. Self-hosted and CPU-friendly, in keeping
/// with the project's "no cloud dependency" default — the only network
/// hop is to a server the operator runs themselves.
@immutable
class OllamaEmbeddingProvider implements EmbeddingProvider {
  /// Creates a provider targeting [baseUrl] (no trailing slash) using
  /// [model]. [client] and [timeout] are overridable for tests; production
  /// callers can omit both.
  OllamaEmbeddingProvider({
    required this.baseUrl,
    required this.model,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  /// Base URL of the Ollama server, e.g. `http://localhost:11434`.
  final String baseUrl;

  /// Ollama model name to embed with, e.g. `nomic-embed-text`.
  final String model;

  /// Per-request timeout; a request that exceeds this is treated as a
  /// failure like any other, per [EmbeddingProviderException].
  final Duration timeout;

  final http.Client _client;

  /// Ollama's API doesn't report an embedding model's output dimension,
  /// so this is a static value rather than a runtime probe. Only
  /// `nomic-embed-text` (768-dim) is supported today — revisit as a
  /// per-model lookup if/when a second model is added.
  @override
  int get dimensions => 768;

  @override
  Future<List<double>> embed(String text) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/api/embeddings'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'model': model, 'prompt': text}),
          )
          .timeout(timeout);
    } catch (e) {
      throw EmbeddingProviderException(
        'Ollama request to $baseUrl failed: $e',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw EmbeddingProviderException(
        'Ollama returned HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw EmbeddingProviderException('Ollama returned invalid JSON: $e');
    }

    if (decoded is! Map<String, dynamic> || decoded['embedding'] is! List) {
      throw EmbeddingProviderException(
        'Ollama response missing an "embedding" array: ${response.body}',
      );
    }

    return (decoded['embedding'] as List)
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
  }
}
