import 'package:server/src/file_references.dart';
import 'package:test/test.dart';

void main() {
  test('reference links images titles and encoded paths identify file owners',
      () {
    final paths = vaultFileReferences(
      '[report](../report.txt "Title")\n![image][ref]\n\n'
          '[ref]: /notes/files/image.png\n\n[encoded](%2E%2E/other.txt)',
      'private',
    );
    expect(paths, containsAll(['report.txt', 'image.png', 'other.txt']));
  });
  test('code examples and malformed URI text cannot claim file ownership', () {
    expect(
      vaultFileReferences('`[example](/notes/files/report.txt)`', ''),
      isEmpty,
    );
    expect(vaultFileReferences('[invalid](%FF)', ''), isEmpty);
  });
}
