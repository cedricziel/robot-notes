import 'package:server/src/embeddings/embedding_provider.dart';

/// Deterministic [EmbeddingProvider] for tests: returns a fixed-dimension
/// vector derived from the input text's hash so distinct texts get distinct
/// (but reproducible) embeddings, without any real model or network call.
class FakeEmbeddingProvider implements EmbeddingProvider {
  FakeEmbeddingProvider({this.dimensions = 4, this.delay = Duration.zero});

  @override
  final int dimensions;

  /// Optional artificial delay before [embed] resolves, for tests that need
  /// to observe concurrency (e.g. "runs alongside the FTS5 query").
  final Duration delay;

  /// Overrides [embed]'s result for a specific input text, bypassing the
  /// hash derivation — useful for constructing a query vector that's
  /// deliberately close/far from a stored one.
  final Map<String, List<double>> overrides = {};

  /// Throws [EmbeddingProviderException] instead of returning a vector, for
  /// exercising failure paths.
  bool shouldThrow = false;

  int callCount = 0;

  /// Every text passed to [embed], in call order, so tests can assert on
  /// what the caller chose to embed (e.g. title + content).
  final List<String> inputs = [];

  @override
  Future<List<double>> embed(String text) async {
    callCount++;
    inputs.add(text);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (shouldThrow) {
      throw const EmbeddingProviderException('fake provider failure');
    }
    final override = overrides[text];
    if (override != null) return override;
    final seed = text.hashCode;
    return List<double>.generate(
      dimensions,
      (i) => ((seed >> i) & 0xff) / 255,
    );
  }
}
