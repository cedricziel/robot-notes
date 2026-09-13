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

  /// Ollama's API doesn't report an embedding model's output dimension, so
  /// this is a static lookup rather than a runtime probe. Keyed by the
  /// model's base name (an optional `:tag` suffix, e.g. `:v1.5`, is
  /// stripped before lookup). `Config` validates `--ollama-embedding-model`
  /// against this map at startup, so an unsupported model is rejected
  /// before a provider is ever constructed.
  static const Map<String, int> knownDimensions = {'nomic-embed-text': 768};

  /// Strips an optional `:tag` suffix (e.g. `nomic-embed-text:v1.5` ->
  /// `nomic-embed-text`) so tagged model names still resolve in
  /// [knownDimensions].
  static String baseModelName(String model) {
    final colon = model.indexOf(':');
    return colon == -1 ? model : model.substring(0, colon);
  }

  @override
  int get dimensions {
    final dim = knownDimensions[baseModelName(model)];
    if (dim == null) {
      // Config validates the model at startup, so this only fires if a
      // provider is constructed by hand, bypassing that check.
      throw StateError('Unknown Ollama embedding model "$model".');
    }
    return dim;
  }

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

    final rawEmbedding = decoded['embedding'] as List;
    if (rawEmbedding.any((e) => e is! num)) {
      throw EmbeddingProviderException(
        'Ollama response "embedding" array contains a non-numeric element: '
        '${response.body}',
      );
    }

    final embedding =
        rawEmbedding.map((e) => (e as num).toDouble()).toList(growable: false);

    if (embedding.length != dimensions) {
      throw EmbeddingProviderException(
        'Ollama returned a ${embedding.length}-dimension embedding for '
        'model "$model", expected $dimensions.',
      );
    }

    return embedding;
  }
}
