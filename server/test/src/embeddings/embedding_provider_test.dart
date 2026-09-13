import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:test/test.dart';

class _FakeProvider implements EmbeddingProvider {
  const _FakeProvider(this.dimensions);

  @override
  final int dimensions;

  @override
  Future<List<double>> embed(String text) async =>
      List<double>.filled(dimensions, 0.5);
}

void main() {
  group('EmbeddingProvider', () {
    test('implementations expose dimensions and embed(text)', () async {
      const provider = _FakeProvider(768);

      expect(provider.dimensions, 768);
      final vector = await provider.embed('hello world');
      expect(vector, hasLength(768));
    });
  });
}
