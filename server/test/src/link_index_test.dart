import 'dart:io';

import 'package:server/src/clock.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('robot-notes-link-index-test-');

void main() {
  group('LinkIndex mutations', () {
    test('upsert records the outgoing edges parsed from content', () {
      final idx = LinkIndex()
        ..upsert('A', 'See [[Project Alpha]] and [[Other|alt]]');
      final edges = idx.outgoing('A');
      expect(edges.map((e) => e.targetTitle), ['Project Alpha', 'Other']);
      expect(edges.map((e) => e.alias), [null, 'alt']);
    });

    test("upsert replaces a note's previous edges entirely", () {
      final idx = LinkIndex()
        ..upsert('A', '[[First]]')
        ..upsert('A', '[[Second]]');
      expect(idx.outgoing('A').map((e) => e.targetTitle), ['Second']);
    });

    test('a note with no links has no outgoing edges', () {
      final idx = LinkIndex()..upsert('A', 'plain text');
      expect(idx.outgoing('A'), isEmpty);
    });

    test('outgoing for an unknown id is empty, not an error', () {
      expect(LinkIndex().outgoing('nope'), isEmpty);
    });

    test("remove drops a note's edges", () {
      final idx = LinkIndex()
        ..upsert('A', '[[Target]]')
        ..remove('A');
      expect(idx.outgoing('A'), isEmpty);
      expect(idx.sourcesLinkingToTitle('Target'), isEmpty);
    });

    test('remove on an unindexed id is a no-op', () {
      expect(() => LinkIndex().remove('nope'), returnsNormally);
    });
  });

  group('LinkIndex.sourcesLinkingToTitle', () {
    test('finds every note whose content links to a given title', () {
      final idx = LinkIndex()
        ..upsert('B', 'refers to [[Old Name]]')
        ..upsert('C', 'also [[Old Name|alias]]')
        ..upsert('D', 'unrelated [[Something Else]]');
      expect(
        idx.sourcesLinkingToTitle('Old Name').toSet(),
        {'B', 'C'},
      );
    });

    test('a title matching no link returns no sources', () {
      final idx = LinkIndex()..upsert('A', '[[Something]]');
      expect(idx.sourcesLinkingToTitle('Nothing'), isEmpty);
    });

    test('an incidental plain-text mention outside [[...]] is not a source',
        () {
      final idx = LinkIndex()..upsert('A', 'Old Name was great');
      expect(idx.sourcesLinkingToTitle('Old Name'), isEmpty);
    });
  });

  group('LinkIndex.scan', () {
    test('rebuilds edges from every note in Storage/MetaIndex', () async {
      final tmp = _tempDir();
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final storage = Storage(
        contentDir: Directory('${tmp.path}/content'),
        clock: FixedClock.fixed(DateTime.utc(2026, 4, 25, 10)),
      );
      final a = await storage.create(title: 'Alpha', content: '');
      final b = await storage.create(
        title: 'Beta',
        content: 'See [[Alpha]]',
      );
      final meta = MetaIndex();
      await meta.scan(storage);

      final linkIdx = LinkIndex();
      final count = await linkIdx.scan(metaIndex: meta, storage: storage);

      expect(count, 2);
      expect(linkIdx.outgoing(a.id), isEmpty);
      expect(linkIdx.outgoing(b.id).single.targetTitle, 'Alpha');
      expect(linkIdx.sourcesLinkingToTitle('Alpha'), [b.id]);
    });
  });
}
