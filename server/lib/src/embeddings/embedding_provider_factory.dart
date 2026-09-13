import 'package:server/src/config.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:server/src/embeddings/ollama_embedding_provider.dart';

/// Builds the [EmbeddingProvider] named by [config], or `null` when none is
/// configured — the single place that maps [Config.embeddingProvider] to a
/// concrete adapter, so no other code needs to know the adapter list.
EmbeddingProvider? embeddingProviderFromConfig(Config config) {
  switch (config.embeddingProvider) {
    case 'ollama':
      return OllamaEmbeddingProvider(
        baseUrl: config.ollamaBaseUrl,
        model: config.ollamaEmbeddingModel,
      );
    default:
      return null;
  }
}
