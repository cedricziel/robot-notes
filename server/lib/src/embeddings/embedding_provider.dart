import 'package:logging/logging.dart';

/// Produces vector embeddings for note content and search queries,
/// decoupling the search index's hybrid ranking from how those vectors are
/// generated. Implementations are expected to be stateless and safe to call
/// concurrently.
abstract class EmbeddingProvider {
  /// Embeds [text], returning a vector of length [dimensions].
  ///
  /// Implementations SHOULD throw an [EmbeddingProviderException] (not a
  /// raw transport exception) on failure, so callers can distinguish "no
  /// embedding produced" from a bug in their own code.
  Future<List<double>> embed(String text);

  /// The fixed length of every vector returned by [embed].
  int get dimensions;
}

/// Thrown by an [EmbeddingProvider] when it fails to produce an embedding
/// (network error, timeout, non-success response, ...). Never a raw
/// HTTP/socket exception, so callers can catch this one type regardless of
/// the underlying provider implementation.
class EmbeddingProviderException implements Exception {
  /// Creates an exception describing why embedding generation failed.
  const EmbeddingProviderException(this.message);

  /// Human-readable description of the failure.
  final String message;

  @override
  String toString() => 'EmbeddingProviderException: $message';
}

/// Best-effort embedding helper shared by the search index's write and
/// query paths: collapses "no provider configured" and "provider
/// configured but failed" into the same `null` result (both mean "proceed
/// without a vector"), while still distinguishing them internally — a
/// failure is logged, an absent provider is not, since there's nothing
/// wrong to report.
///
/// Blank [text] (empty or whitespace-only) short-circuits to `null` without
/// calling the provider at all: there is nothing to embed, and asking a
/// model anyway yields a degenerate (often zero-length) vector that would
/// only be reported as a failure.
Future<List<double>?> embedOrNull(
  EmbeddingProvider? provider,
  String text, {
  Logger? logger,
}) async {
  if (provider == null) return null;
  if (text.trim().isEmpty) return null;
  try {
    return await provider.embed(text);
  } on EmbeddingProviderException catch (e) {
    (logger ?? Logger('embedding_provider')).warning(
      'Embedding provider failed, continuing without a vector: $e',
    );
    return null;
  }
}

/// The text a note is embedded from: its [title] followed by its [content],
/// separated by a blank line, with surrounding whitespace trimmed. Titles
/// carry meaning of their own (a note titled "Melanie" with an empty body
/// should still be findable by a semantic query), and a note whose body is
/// blank would otherwise have nothing to embed at all. Shared by the write
/// path and the backfill so both produce comparable vectors.
String embeddingInputFor({required String title, required String content}) {
  final t = title.trim();
  final c = content.trim();
  if (t.isEmpty) return c;
  if (c.isEmpty) return t;
  return '$t\n\n$c';
}
