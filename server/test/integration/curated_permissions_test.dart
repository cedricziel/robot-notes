import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server/src/app_deps.dart';
import 'package:server/src/frontmatter.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart';

import '_test_app.dart';

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.start();
  });
  tearDown(() async {
    await app.close();
  });

  Future<Map<String, dynamic>> create(String title, {String path = ''}) async {
    final response = await http.post(
      Uri.parse('${app.baseUrl}/notes'),
      headers: app.headers(),
      body: jsonEncode({'title': title, 'content': 'accepted', 'path': path}),
    );
    expect(response.statusCode, 201, reason: response.body);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  test('known agents cannot save append delete or patch accepted curated notes',
      () async {
    final note = await create('Curated', path: 'institution');
    await app.deps.authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'institution',
      KnowledgePolicyPatch(curated: true),
    );
    final credential = await app.deps.agentCredentials.issue(
      actor: 'human',
      scopes: {
        'notes:read',
        'notes:write',
        'knowledge:propose',
        'knowledge:edit',
      },
    );
    final headers = {
      'Authorization': 'Bearer ${credential.secret}',
      'X-Actor': 'operator',
      'Content-Type': 'application/json',
      'If-Match': '1',
    };
    final save = await http.put(
      Uri.parse('${app.baseUrl}/notes/${note['id']}'),
      headers: headers,
      body: jsonEncode({'title': 'Curated', 'content': 'bad'}),
    );
    final append = await http.post(
      Uri.parse('${app.baseUrl}/notes/${note['id']}/append'),
      headers: headers,
      body: jsonEncode({'content': 'bad'}),
    );
    final remove = await http.delete(
      Uri.parse('${app.baseUrl}/notes/${note['id']}'),
      headers: headers,
    );
    final patch = await http.patch(
      Uri.parse('${app.baseUrl}/notes/${note['id']}/properties'),
      headers: headers,
      body: jsonEncode({
        'set': {'x': 'bad'},
      }),
    );
    expect(save.statusCode, 403, reason: save.body);
    expect(append.statusCode, 403, reason: append.body);
    expect(remove.statusCode, 403, reason: remove.body);
    expect(patch.statusCode, 403, reason: patch.body);
    expect(
      (await app.deps.storage.read(note['id'] as String)).content,
      'accepted',
    );
  });

  test('read denial also prevents source-reading accepted mutations', () async {
    final note = await create('Private');
    final credential = await app.deps.agentCredentials.issue(actor: 'writer');
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(note['id'] as String, ''),
      KnowledgePolicyPatch(
        access: {
          KnowledgeAction.read: {},
          KnowledgeAction.edit: {'*'},
        },
      ),
    );
    final response = await http.put(
      Uri.parse('${app.baseUrl}/notes/${note['id']}'),
      headers: {
        'Authorization': 'Bearer ${credential.secret}',
        'Content-Type': 'application/json',
        'If-Match': '1',
      },
      body: jsonEncode({'title': 'Private', 'content': 'bad'}),
    );
    expect(response.statusCode, 403, reason: response.body);
    expect(response.body, isNot(contains('accepted')));
    expect(
      (await app.deps.storage.read(note['id'] as String)).content,
      'accepted',
    );
  });

  test('a forgotten request identity cannot mutate even ordinary notes',
      () async {
    final note = await create('Ordinary');
    final unscoped = NoteWriteService(
      storage: app.deps.storage,
      metaIndex: app.deps.metaIndex,
      searchIndex: app.deps.searchIndex,
      broadcaster: app.deps.broadcaster,
      authorization: app.deps.authorization,
    );
    await expectLater(
      unscoped.update(
        id: note['id'] as String,
        title: 'Ordinary',
        content: 'bad',
        ifMatch: 1,
        actor: 'operator',
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect(
      (await app.deps.storage.read(note['id'] as String)).content,
      'accepted',
    );
  });

  test('moving a readable note cannot weaken access without policy authority',
      () async {
    final note = await create('Private', path: 'private');
    final credential = await app.deps.agentCredentials.issue(actor: 'agent');
    await app.deps.authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'private',
      KnowledgePolicyPatch(
        access: {
          KnowledgeAction.read: {'agent:${credential.record.id}'},
        },
      ),
    );
    final response = await http.put(
      Uri.parse('${app.baseUrl}/notes/${note['id']}'),
      headers: {
        'Authorization': 'Bearer ${credential.secret}',
        'Content-Type': 'application/json',
        'If-Match': '1',
      },
      body:
          jsonEncode({'title': 'Private', 'content': 'bad', 'path': 'public'}),
    );
    expect(response.statusCode, 403, reason: response.body);
    expect((await app.deps.storage.read(note['id'] as String)).path, 'private');
  });
  test('policy designation immediately initializes maps and survives restart',
      () async {
    final note = await create('Institution');
    final id = note['id'] as String;
    final response = await http.put(
      Uri.parse('${app.baseUrl}/knowledge/policies'),
      headers: {...app.headers(), 'If-Match': '0'},
      body: jsonEncode({
        'target': {'kind': 'note', 'id': id},
        'policy': {'curated': true},
      }),
    );
    expect(response.statusCode, 200, reason: response.body);
    expect((await app.deps.storage.readBlockMap(id)).version, 1);
    final permission = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/permissions'),
      headers: app.headers(),
    );
    expect((jsonDecode(permission.body) as Map)['curated'], true);
    final stale = await http.put(
      Uri.parse('${app.baseUrl}/knowledge/policies'),
      headers: {...app.headers(), 'If-Match': '0'},
      body: jsonEncode({
        'target': {'kind': 'note', 'id': id},
        'policy': <String, Object?>{},
      }),
    );
    expect(stale.statusCode, 409);
    final config = app.config;
    final dir = app.tmpDir;
    await app.close(deleteDir: false);
    final deps = await AppDeps.bootstrap(config);
    app = TestApp.wrap(
      await startTestServer(deps: deps, config: config),
      deps,
      config,
      dir,
    );
    expect(
      app.deps.authorization.store
          .effective(KnowledgeTarget.note(id, ''))
          .curated,
      true,
    );
    expect((await app.deps.storage.readBlockMap(id)).matches('accepted'), true);
  });

  test('private entries cannot consume public limits or counts', () async {
    final private = await create('Hidden searchword', path: 'private');
    final visible = await create('Visible searchword', path: 'public');
    await http.put(
      Uri.parse('${app.baseUrl}/notes/${private['id']}'),
      headers: {...app.headers(), 'If-Match': '1'},
      body: jsonEncode({'content': 'searchword #secret'}),
    );
    await app.deps.authorization.putFolderPolicy(
      const KnowledgePrincipal.operator(),
      'private',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    final credential = await app.deps.agentCredentials.issue(actor: 'reader');
    final headers = {'Authorization': 'Bearer ${credential.secret}'};
    final page = await http.get(
      Uri.parse('${app.baseUrl}/notes?limit=1'),
      headers: headers,
    );
    final data = jsonDecode(page.body) as Map;
    expect(
      ((data['items'] as List).single as Map<String, dynamic>)['id'],
      visible['id'],
    );
    expect(data['next_cursor'], null);
    final search = await http.get(
      Uri.parse('${app.baseUrl}/search?q=searchword&limit=1'),
      headers: headers,
    );
    expect(
      (((jsonDecode(search.body) as Map)['items'] as List).single
          as Map<String, dynamic>)['id'],
      visible['id'],
    );
    final tags =
        await http.get(Uri.parse('${app.baseUrl}/tags'), headers: headers);
    expect(tags.body, isNot(contains('secret')));
    final tree = await http.get(
      Uri.parse('${app.baseUrl}/notes/tree'),
      headers: headers,
    );
    expect(tree.body, isNot(contains('private')));
  });

  test('raw canonical files honor note overrides and private attachment owners',
      () async {
    final private = await create('Private');
    final id = private['id'] as String;
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(id, ''),
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    final credential = await app.deps.agentCredentials.issue(actor: 'reader');
    final raw = await http.get(
      Uri.parse('${app.baseUrl}/notes/files/Private.md'),
      headers: {'Authorization': 'Bearer ${credential.secret}'},
    );
    expect(raw.statusCode, 403);
    expect(raw.body, isNot(contains('accepted')));
    await File('${app.deps.storage.contentDir.path}/report.txt')
        .writeAsString('private attachment');
    app.deps.storage.registerFile(
      StoredFile(
        relativePath: 'report.txt',
        size: 18,
        updatedAt: DateTime.utc(2026),
      ),
    );
    await http.put(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: {...app.headers(), 'If-Match': '1'},
      body: jsonEncode({
        'content':
            '[report][file]\n\n[file]: /notes/files/report.txt "Private"',
      }),
    );
    final attachment = await http.get(
      Uri.parse('${app.baseUrl}/notes/files/report.txt'),
      headers: {'Authorization': 'Bearer ${credential.secret}'},
    );
    expect(attachment.statusCode, 403);
    final tree = await http.get(
      Uri.parse('${app.baseUrl}/notes/tree'),
      headers: {'Authorization': 'Bearer ${credential.secret}'},
    );
    expect((jsonDecode(tree.body) as Map)['folders'], isEmpty);
  });

  test('canonical uploads cannot replace curated IDs after restart', () async {
    final note = await create('Curated');
    final id = note['id'] as String;
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(id, ''),
      KnowledgePolicyPatch(curated: true),
    );
    final credential = await app.deps.agentCredentials.issue(actor: 'writer');
    final canonical = serializeFrontmatter(
      Frontmatter(
        metadata: {
          'id': id,
          'title': 'Injected',
          'version': 99,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
        body: 'corrupt accepted knowledge',
      ),
    );
    final request =
        http.MultipartRequest('POST', Uri.parse('${app.baseUrl}/notes/files'))
          ..headers['Authorization'] = 'Bearer ${credential.secret}'
          ..fields['path'] = 'ordinary'
          ..files.add(
            http.MultipartFile.fromString(
              'file',
              canonical,
              filename: 'alias.txt',
            ),
          );
    final response = await request.send();
    expect(
      response.statusCode,
      422,
      reason: await response.stream.bytesToString(),
    );
    expect(
      File('${app.deps.storage.contentDir.path}/ordinary/alias.txt')
          .existsSync(),
      false,
    );
    final plain = http.MultipartRequest(
      'POST',
      Uri.parse('${app.baseUrl}/notes/files'),
    )
      ..headers['Authorization'] = 'Bearer ${credential.secret}'
      ..fields['path'] = ''
      ..files.add(
        http.MultipartFile.fromString(
          'file',
          '# Plain attachment',
          filename: 'plain.md',
        ),
      );
    expect((await plain.send()).statusCode, 201);
    final config = app.config;
    final dir = app.tmpDir;
    await app.close(deleteDir: false);
    final deps = await AppDeps.bootstrap(config);
    app = TestApp.wrap(
      await startTestServer(deps: deps, config: config),
      deps,
      config,
      dir,
    );
    expect((await app.deps.storage.read(id)).content, 'accepted');
    expect((await app.deps.storage.read(id)).version, 1);
    expect(
      app.deps.storage
          .filesIn('')
          .any((file) => file.relativePath == 'plain.md'),
      true,
    );
  });

  test('wrong upload issuers cannot consume reservations', () async {
    final issuer = await app.deps.agentCredentials.issue(actor: 'issuer');
    final other = await app.deps.agentCredentials.issue(actor: 'other');
    final identity = KnowledgePrincipal.agent(
      credentialId: issuer.record.id,
      scopes: issuer.record.scopes,
    );
    final stranger = KnowledgePrincipal.agent(
      credentialId: other.record.id,
      scopes: other.record.scopes,
    );
    final slot = await withKnowledgePrincipal(
      identity,
      () async => app.deps.uploadSessions
          .reserve(path: '', filename: 'attachment.txt', maxBytes: 100),
    );
    await app.deps.uploadSessions
        .complete(token: slot.token, bytes: Stream.value(utf8.encode('file')));
    await expectLater(
      withKnowledgePrincipal(
        stranger,
        () => app.deps.uploadSessions.finalize(slot.token, app.deps.fileStore),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    final result = await withKnowledgePrincipal(
      identity,
      () => app.deps.uploadSessions.finalize(slot.token, app.deps.fileStore),
    );
    expect(result.filename, 'attachment.txt');
  });

  test('revoked upload issuers and newly curated destinations cannot publish',
      () async {
    final issuer = await app.deps.agentCredentials.issue(actor: 'issuer');
    final identity = KnowledgePrincipal.agent(
      credentialId: issuer.record.id,
      scopes: issuer.record.scopes,
    );
    final slot = await withKnowledgePrincipal(
      identity,
      () async => app.deps.uploadSessions
          .reserve(path: '', filename: 'revoked.txt', maxBytes: 100),
    );
    await app.deps.uploadSessions
        .complete(token: slot.token, bytes: Stream.value(utf8.encode('file')));
    await app.deps.agentCredentials.revoke(issuer.record.id);
    await expectLater(
      withKnowledgePrincipal(
        identity,
        () => app.deps.uploadSessions.finalize(slot.token, app.deps.fileStore),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect(
      File('${app.deps.storage.contentDir.path}/revoked.txt').existsSync(),
      false,
    );
  });
  test('legacy immutable history gets a fresh mapped accepted revision',
      () async {
    final note = await create('Legacy');
    final id = note['id'] as String;
    await app.deps.storage.enableRevisionHistory(id);
    final snapshot = File(
      '${app.deps.storage.contentDir.path}.history/${base64Url.encode(utf8.encode(id))}/1.json',
    );
    final raw = (jsonDecode(await snapshot.readAsString())
        as Map<String, dynamic>)
      ..remove('block_map');
    final immutable = jsonEncode(raw);
    await snapshot.writeAsString(immutable);
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(id, ''),
      KnowledgePolicyPatch(curated: true),
    );
    expect(await snapshot.readAsString(), immutable);
    expect((await app.deps.storage.read(id)).version, 2);
    expect((await app.deps.storage.readBlockMap(id)).version, 2);
  });

  test('vault management grants cannot edit or purge curated notes', () async {
    final note = await create('Protected');
    final id = note['id'] as String;
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(id, ''),
      KnowledgePolicyPatch(curated: true),
    );
    final tokens = await app.deps.tokenStore.issue(
      clientId: 'oidc',
      resource: app.baseUrl,
      scopes: {'notes:read', 'notes:write', 'vaults:manage'},
      actor: 'human',
      grantId: 'self-requested',
    );
    final headers = {
      'Authorization': 'Bearer ${tokens.accessToken}',
      'Content-Type': 'application/json',
      'If-Match': '1',
    };
    final write = await http.put(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: headers,
      body: jsonEncode({'content': 'unauthorized'}),
    );
    expect(write.statusCode, 403, reason: write.body);
    final purge = await http.delete(
      Uri.parse('${app.baseUrl}/notes/$id/history'),
      headers: headers,
    );
    expect(purge.statusCode, 403, reason: purge.body);
    expect((await app.deps.storage.read(id)).content, 'accepted');
    expect(await app.deps.storage.revisions(id), hasLength(1));
  });

  test('policy-only managers can configure notes without ordinary write scope',
      () async {
    final note = await create('Managed');
    final id = note['id'] as String;
    final tokens = await app.deps.tokenStore.issue(
      clientId: 'policy',
      resource: app.baseUrl,
      scopes: {'notes:read', 'knowledge:policy'},
      actor: 'Policy manager',
      grantId: 'policy-grant',
    );
    final response = await http.put(
      Uri.parse('${app.baseUrl}/knowledge/policies'),
      headers: {
        'Authorization': 'Bearer ${tokens.accessToken}',
        'Content-Type': 'application/json',
        'If-Match': '0',
      },
      body: jsonEncode({
        'target': {'kind': 'note', 'id': id},
        'policy': {'curated': true},
      }),
    );
    expect(response.statusCode, 200, reason: response.body);
    final directory = await http.get(
      Uri.parse('${app.baseUrl}/knowledge/principals?kind=note&id=$id'),
      headers: {'Authorization': 'Bearer ${tokens.accessToken}'},
    );
    expect(directory.statusCode, 200, reason: directory.body);
    expect(directory.body, contains('oauth:policy-grant'));
    expect(directory.body, isNot(contains('token_hash')));
    expect(directory.body, isNot(contains(tokens.accessToken)));
  });

  test('rename propagation does not mutate a curated referencing note',
      () async {
    final origin = await create('Source');
    final reference = await create('Reference');
    await http.put(
      Uri.parse('${app.baseUrl}/notes/${reference['id']}'),
      headers: {...app.headers(), 'If-Match': '1'},
      body: jsonEncode({'content': '[[Source]]'}),
    );
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(reference['id'] as String, ''),
      KnowledgePolicyPatch(curated: true),
    );
    final credential = await app.deps.agentCredentials.issue(actor: 'writer');
    final rename = await http.put(
      Uri.parse('${app.baseUrl}/notes/${origin['id']}'),
      headers: {
        'Authorization': 'Bearer ${credential.secret}',
        'Content-Type': 'application/json',
        'If-Match': '1',
      },
      body: jsonEncode({'title': 'Renamed', 'content': 'accepted'}),
    );
    expect(rename.statusCode, 200, reason: rename.body);
    final untouched = await app.deps.storage.read(reference['id'] as String);
    expect(untouched.content, '[[Source]]');
    expect(untouched.version, 2);
  });
  test('an agent-origin operator cannot race curation or weaken policy',
      () async {
    final note = await create('Becomes curated');
    final id = note['id'] as String;
    final headers = {
      ...app.headers(),
      'X-Robot-Notes-Agent': 'true',
      'If-Match': '1',
    };
    final before = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/permissions'),
      headers: headers,
    );
    expect((jsonDecode(before.body) as Map)['curated'], false);
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(id, ''),
      KnowledgePolicyPatch(curated: true),
    );
    final write = await http.put(
      Uri.parse('${app.baseUrl}/notes/$id'),
      headers: headers,
      body: jsonEncode({'content': 'raced accepted edit'}),
    );
    expect(write.statusCode, 403, reason: write.body);
    final weaken = await http.put(
      Uri.parse('${app.baseUrl}/knowledge/policies'),
      headers: {...headers, 'If-Match': '1'},
      body: jsonEncode({
        'target': {'kind': 'note', 'id': id},
        'policy': {'curated': false},
      }),
    );
    expect(weaken.statusCode, 403, reason: weaken.body);
    final after = await http.get(
      Uri.parse('${app.baseUrl}/notes/$id/permissions'),
      headers: headers,
    );
    final data = jsonDecode(after.body) as Map<String, dynamic>;
    expect(data['principal_kind'], 'operator');
    expect(data['agent_origin'], true);
    expect(data['allowed_actions'], contains('propose'));
    expect(data['allowed_actions'], isNot(contains('review')));
    expect((await app.deps.storage.read(id)).content, 'accepted');
  });
  test('ordinary editor locks work while curated agent lock mutations deny',
      () async {
    final ordinary = await create('Ordinary editor');
    final curated = await create('Curated editor');
    await app.deps.authorization.putNotePolicy(
      const KnowledgePrincipal.operator(),
      KnowledgeTarget.note(curated['id'] as String, ''),
      KnowledgePolicyPatch(curated: true),
    );
    final credential = await app.deps.agentCredentials.issue(actor: 'editor');
    final headers = {
      'Authorization': 'Bearer ${credential.secret}',
      'X-Actor': 'owner',
    };
    final positive = await http.post(
      Uri.parse('${app.baseUrl}/notes/${ordinary['id']}/lock'),
      headers: headers,
    );
    expect(positive.statusCode, 200, reason: positive.body);
    expect((jsonDecode(positive.body) as Map)['holder'], 'editor');
    for (final method in ['POST', 'PUT', 'DELETE']) {
      final request = http.Request(
        method,
        Uri.parse('${app.baseUrl}/notes/${curated['id']}/lock'),
      )..headers.addAll(headers);
      final response = await request.send();
      expect(
        response.statusCode,
        403,
        reason: await response.stream.bytesToString(),
      );
    }
    expect(app.deps.lockManager.lockOf(curated['id'] as String), null);
  });
  test('a writer cannot omit policy even inside an authenticated agent context',
      () async {
    final identity = KnowledgePrincipal.agent(
      credentialId: 'authenticated',
      scopes: {'notes:read', 'notes:write'},
    );
    await withKnowledgePrincipal(identity, () async {
      expect(
        () => NoteWriteService(
          storage: app.deps.storage,
          metaIndex: app.deps.metaIndex,
          searchIndex: app.deps.searchIndex,
          broadcaster: app.deps.broadcaster,
        ),
        throwsArgumentError,
      );
    });
  });
}
