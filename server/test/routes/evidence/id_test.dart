import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/evidence_store.dart';
import 'package:server/src/rest_principal.dart';
import 'package:test/test.dart';

import '../../../routes/evidence/[id].dart' as route;

class _Context extends Mock implements RequestContext {}

void main() {
  late Directory directory;
  late EvidenceStore store;
  const payload = '{"session_id":"session","kind":"turn","messages":'
      '[{"role":"tool","content":"complete result"}]}';
  final id = sha256.convert(utf8.encode(payload)).toString();

  setUp(() {
    directory = Directory.systemTemp.createTempSync('robot-evidence-route-');
    store = EvidenceStore(
      file: File('${directory.path}/evidence.db'),
      clock: FixedClock.fixed(DateTime.utc(2026, 10, 11)),
    );
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  Future<Response> request(
    HttpMethod method, {
    Object? body,
    RestPrincipal principal = const RestPrincipal.staticKey(),
  }) {
    final context = _Context();
    final request = Request(
      method.name.toUpperCase(),
      Uri.parse('http://localhost/evidence/$id'),
      body: body == null ? null : jsonEncode(body),
    );
    when(() => context.request).thenReturn(request);
    when(() => context.read<EvidenceStore>()).thenReturn(store);
    when(() => context.read<RestPrincipal>()).thenReturn(principal);
    return route.onRequest(context, id);
  }

  test('PUT acknowledges stored content and GET returns original metadata',
      () async {
    final write = await request(
      HttpMethod.put,
      body: {
        'payload': payload,
        'retention_days': 7,
        'lineage': {'reset': true},
      },
    );
    expect(write.statusCode, 200);
    final read = await request(HttpMethod.get);
    expect(await read.json(), await write.json());
    expect((await read.json() as Map)['payload'], payload);
  });

  test('invalid digest content is rejected without writing', () async {
    final write = await request(
      HttpMethod.put,
      body: {'payload': '$payload ', 'retention_days': 7},
    );
    expect(write.statusCode, 400);
    expect(store.read(id), isNull);
  });

  test('OAuth writers cannot purge evidence', () async {
    store.put(id, payload, retentionDays: 7);
    final denied = await request(
      HttpMethod.delete,
      principal:
          const RestPrincipal.oauth(actor: 'agent', scopes: {'notes:write'}),
    );
    expect(denied.statusCode, 403);
    expect(store.read(id), isNotNull);
  });

  test('operator purge cannot be undone by a repeated PUT', () async {
    store.put(id, payload, retentionDays: 7);
    expect((await request(HttpMethod.delete)).statusCode, 204);
    final retry = await request(
      HttpMethod.put,
      body: {'payload': payload, 'retention_days': 7},
    );
    expect(retry.statusCode, 410);
    expect((await request(HttpMethod.get)).statusCode, 404);
  });

  test('retention outside supported bounds is rejected', () async {
    final write = await request(
      HttpMethod.put,
      body: {'payload': payload, 'retention_days': 3651},
    );
    expect(write.statusCode, 400);
    expect(store.read(id), isNull);
  });
}
