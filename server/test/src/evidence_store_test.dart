import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/evidence_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  final epoch = DateTime.utc(2026, 10, 11);
  const payload = '{"session_id":"session","kind":"turn","messages":'
      '[{"role":"tool","content":"complete result"}]}';
  final id = sha256.convert(utf8.encode(payload)).toString();
  EvidenceStore open(DateTime now) => EvidenceStore(
        file: File('${directory.path}/evidence.db'),
        clock: FixedClock.fixed(now),
      );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('robot-evidence-test-');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('acknowledged evidence survives reopening without note files', () {
    final store = open(epoch);
    final first = store.put(id, payload, retentionDays: 7);
    store.close();
    final reopened = open(epoch);
    addTearDown(reopened.close);
    expect(reopened.read(id), first);
    expect(first['payload'], payload);
    expect(Directory('${directory.path}/content').existsSync(), isFalse);
  });

  test('retries retain original expiry and lineage', () {
    final store = open(epoch);
    final first = store.put(
      id,
      payload,
      retentionDays: 7,
      lineage: const {'parent_session_id': 'parent'},
    );
    store.close();
    final reopened = open(epoch.add(const Duration(days: 1)));
    addTearDown(reopened.close);
    expect(reopened.put(id, payload, retentionDays: 30), first);
  });

  test('expired evidence cannot be read after restart', () {
    open(epoch)
      ..put(id, payload, retentionDays: 1)
      ..close();
    final reopened = open(epoch.add(const Duration(days: 1)));
    addTearDown(reopened.close);
    expect(reopened.read(id), isNull);
  });

  test('digest mismatch cannot replace existing evidence', () {
    final store = open(epoch)..put(id, payload, retentionDays: 7);
    addTearDown(store.close);
    expect(
      () => store.put(id, '$payload ', retentionDays: 7),
      throwsFormatException,
    );
    expect(store.read(id)!['payload'], payload);
  });

  test('explicit deletion removes evidence', () {
    final store = open(epoch)..put(id, payload, retentionDays: 7);
    addTearDown(store.close);
    store.delete(id);
    expect(store.read(id), isNull);
  });
}
