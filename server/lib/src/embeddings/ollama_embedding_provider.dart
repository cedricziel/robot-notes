import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:server/src/embeddings/embedding_provider.dart';

/// [EmbeddingProvider] backed by a local Ollama instance's `/api/embed`
/// endpoint. Self-hosted and CPU-friendly, in keeping with the project's
/// "no cloud dependency" default — the only network hop is to a server the
/// operator runs themselves.
///
/// Requests ask Ollama to `truncate` input that exceeds the model's context
/// and pass `num_ctx` explicitly (see [contextLength]): Ollama loads
/// embedding models with a 2048-token context by default and the legacy
/// `/api/embeddings` endpoint rejects longer input outright, so a long note
/// would otherwise never get a vector.
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

  /// Maximum input context (in tokens) each known model supports, sent to
  /// Ollama as `options.num_ctx` so it doesn't fall back to its 2048-token
  /// default. Same keying rules as [knownDimensions].
  static const Map<String, int> knownContextLengths = {
    'nomic-embed-text': 8192,
  };

  /// Context length assumed for a model missing from [knownContextLengths]
  /// (Ollama's own default).
  static const int defaultContextLength = 2048;

  /// Rough upper bound on characters per token for prose and markdown;
  /// used to cap the request body client-side so a very large note isn't
  /// shipped in full only for Ollama to discard most of it.
  static const int _charsPerToken = 4;

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

  /// Token context the model is loaded with for this provider's requests.
  int get contextLength =>
      knownContextLengths[baseModelName(model)] ?? defaultContextLength;

  /// Longest input (in characters) sent to Ollama; anything beyond it is
  /// dropped before the request. Ollama still truncates to the exact token
  /// budget server-side, so this only bounds the payload.
  int get maxInputChars => contextLength * _charsPerToken;

  @override
  Future<List<double>> embed(String text) async {
    if (text.trim().isEmpty) {
      throw const EmbeddingProviderException(
        'Refusing to embed blank text: Ollama returns an empty vector for '
        'an empty prompt.',
      );
    }
    final input =
        text.length > maxInputChars ? text.substring(0, maxInputChars) : text;

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/api/embed'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'input': input,
              'truncate': true,
              'options': {'num_ctx': contextLength},
            }),
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

    // `/api/embed` batches: one input in, a list of one vector out.
    if (decoded is! Map<String, dynamic> || decoded['embeddings'] is! List) {
      throw EmbeddingProviderException(
        'Ollama response missing an "embeddings" array: ${response.body}',
      );
    }
    final vectors = decoded['embeddings'] as List;
    if (vectors.isEmpty || vectors.first is! List) {
      throw EmbeddingProviderException(
        'Ollama response "embeddings" array is empty: ${response.body}',
      );
    }

    final rawEmbedding = vectors.first as List;
    if (rawEmbedding.any((e) => e is! num)) {
      throw EmbeddingProviderException(
        'Ollama response "embeddings" vector contains a non-numeric element: '
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
