import 'package:logging/logging.dart';
import 'package:server/src/embeddings/embedding_provider.dart';
import 'package:test/test.dart';

class _StubProvider implements EmbeddingProvider {
  _StubProvider(this._result);

  final Object _result; // List<double> or an Exception to throw

  int calls = 0;

  @override
  int get dimensions => 3;

  @override
  Future<List<double>> embed(String text) async {
    calls++;
    if (_result is Exception) throw _result;
    return _result as List<double>;
  }
}

void main() {
  group('embedOrNull', () {
    test('returns null without calling anything when provider is null',
        () async {
      final result = await embedOrNull(null, 'hello');
      expect(result, isNull);
    });

    test('returns the vector when the provider succeeds', () async {
      final provider = _StubProvider(const [0.1, 0.2, 0.3]);
      final result = await embedOrNull(provider, 'hello');
      expect(result, const [0.1, 0.2, 0.3]);
      expect(provider.calls, 1);
    });

    test(
        'returns null for blank text without calling the provider or '
        'logging', () async {
      final provider = _StubProvider(const [0.1, 0.2, 0.3]);
      final logger = Logger.detached('embed_or_null_test')..level = Level.ALL;
      final logged = <String>[];
      final sub = logger.onRecord.listen((rec) => logged.add(rec.message));

      expect(await embedOrNull(provider, '', logger: logger), isNull);
      expect(await embedOrNull(provider, ' \n\t ', logger: logger), isNull);

      expect(provider.calls, 0);
      expect(logged, isEmpty);
      await sub.cancel();
    });

    test(
        'returns null and logs a warning (distinct from "no provider") '
        'when the provider throws', () async {
      final provider = _StubProvider(
        const EmbeddingProviderException('boom'),
      );
      final logger = Logger.detached('embed_or_null_test')..level = Level.ALL;
      final logged = <String>[];
      final sub = logger.onRecord.listen((rec) => logged.add(rec.message));

      final result = await embedOrNull(provider, 'hello', logger: logger);

      expect(result, isNull);
      expect(provider.calls, 1);
      expect(logged, isNotEmpty);
      await sub.cancel();
    });
  });

  group('embeddingInputFor', () {
    test('joins title and content with a blank line', () {
      expect(
        embeddingInputFor(title: 'Melanie', content: 'Met at the conference.'),
        'Melanie\n\nMet at the conference.',
      );
    });

    test('falls back to the title alone when content is blank', () {
      expect(embeddingInputFor(title: 'Melanie', content: '  \n'), 'Melanie');
    });

    test('falls back to the content alone when the title is blank', () {
      expect(embeddingInputFor(title: '', content: 'body'), 'body');
    });

    test('is blank when both are blank', () {
      expect(embeddingInputFor(title: ' ', content: ''), isEmpty);
    });
  });
}
