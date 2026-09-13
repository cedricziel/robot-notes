import 'package:server/src/config.dart';
import 'package:server/src/embeddings/embedding_provider_factory.dart';
import 'package:server/src/embeddings/ollama_embedding_provider.dart';
import 'package:test/test.dart';

Config _config(List<String> args) =>
    Config.fromArgs(['--api-key', 'rn_x', ...args], env: const {});

void main() {
  group('embeddingProviderFromConfig', () {
    test('returns null when embeddingProvider is unset', () {
      final provider = embeddingProviderFromConfig(_config(const []));
      expect(provider, isNull);
    });

    test('returns an OllamaEmbeddingProvider when configured', () {
      final provider = embeddingProviderFromConfig(
        _config(const [
          '--embedding-provider',
          'ollama',
          '--ollama-base-url',
          'http://ollama.local:11434',
          '--ollama-embedding-model',
          'nomic-embed-text',
        ]),
      );

      expect(provider, isA<OllamaEmbeddingProvider>());
      final ollama = provider! as OllamaEmbeddingProvider;
      expect(ollama.baseUrl, 'http://ollama.local:11434');
      expect(ollama.model, 'nomic-embed-text');
    });
  });
}
