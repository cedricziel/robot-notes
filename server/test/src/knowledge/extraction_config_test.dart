import 'package:server/src/config.dart';
import 'package:test/test.dart';

void main() {
  test(
      'extraction requires explicit destination and model but '
      'stays disabled by default', () {
    final config = Config.fromArgs(
      const [],
      env: const {'ROBOT_NOTES_API_KEY': 'server-key'},
    );
    expect(config.knowledgeEnabled, isFalse);
    expect(config.extraction, isNull);
    expect(
      () => Config.fromArgs(
        const [],
        env: const {
          'ROBOT_NOTES_API_KEY': 'server-key',
          'ROBOT_NOTES_EXTRACTION_MODEL': 'model-only',
        },
      ),
      throwsA(isA<ConfigError>()),
    );
  });
  test('CLI overrides environment and bounds extraction independently', () {
    final config = Config.fromArgs(
      const [
        '--knowledge-enabled',
        '--extraction-model',
        'selected',
        '--extraction-max-candidates',
        '4',
      ],
      env: const {
        'ROBOT_NOTES_API_KEY': 'server-key',
        'ROBOT_NOTES_KNOWLEDGE_ENABLED': 'false',
        'ROBOT_NOTES_EXTRACTION_ENDPOINT': 'http://localhost:8000/v1',
        'ROBOT_NOTES_EXTRACTION_MODEL': 'environment-model',
        'ROBOT_NOTES_EXTRACTION_API_KEY': 'model-key',
      },
    );
    expect(config.knowledgeEnabled, isTrue);
    expect(config.extraction!.model, 'selected');
    expect(config.extraction!.maxCandidates, 4);
    expect(config.extraction!.endpoint.toString(), 'http://localhost:8000/v1');
  });
}
