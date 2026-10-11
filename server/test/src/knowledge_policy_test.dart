import 'dart:async';
import 'dart:io';

import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late KnowledgePolicyStore store;
  late NoteAuthorizationService authorization;
  const operator = KnowledgePrincipal.operator();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('knowledge-policy-test-');
    store = KnowledgePolicyStore(file: File('${tmp.path}/policies.json'));
    await store.load();
    authorization = NoteAuthorizationService(store: store);
  });
  tearDown(() async {
    await store.dispose();
    tmp.deleteSync(recursive: true);
  });

  KnowledgePrincipal agent({Set<String>? scopes}) => KnowledgePrincipal.agent(
        credentialId: 'worker',
        scopes: scopes ?? {'notes:read', 'notes:write', 'knowledge:propose'},
      );

  test('deferred work from an expired mutation lease reacquires the lock',
      () async {
    final trigger = Completer<void>();
    final blockerEntered = Completer<void>();
    final releaseBlocker = Completer<void>();
    var deferredRan = false;
    late Future<void> deferred;
    await store.withMutationLock(() async {
      deferred = trigger.future.then(
        (_) => store.withMutationLock(() async {
          deferredRan = true;
        }),
      );
    });
    final blocker = store.withMutationLock(() async {
      blockerEntered.complete();
      await releaseBlocker.future;
    });
    await blockerEntered.future;
    trigger.complete();
    await Future<void>.delayed(Duration.zero);
    expect(deferredRan, isFalse);
    releaseBlocker.complete();
    await Future.wait([blocker, deferred]);
    expect(deferredRan, isTrue);
  });

  test('selected vault grants apply inside the authorization service', () {
    final otherVault =
        NoteAuthorizationService(store: store, vaultId: 'private');
    expect(
      otherVault.allows(
        agent(),
        KnowledgeAction.read,
        KnowledgeTarget.folder(''),
      ),
      isFalse,
    );
  });

  test('archive collection reads do not follow from review authority', () {
    final reviewer = KnowledgePrincipal.oauth(
      grantId: 'reviewer',
      scopes: {'knowledge:review'},
    );
    expect(
      () => authorization.requireEvidenceRead(
        reviewer,
        '0000000000000000000000000000000000000000000000000000000000000000',
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
  });

  test('archive read restrictions persist independently of note policy',
      () async {
    await authorization.putEvidenceArchivePolicy(
      operator,
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    final reopened = KnowledgePolicyStore(file: store.file);
    await reopened.load();
    addTearDown(reopened.dispose);
    final archive = NoteAuthorizationService(store: reopened);
    expect(
      () => archive.requireEvidenceRead(
        agent(),
        '0000000000000000000000000000000000000000000000000000000000000000',
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
    expect(
      archive.allows(
        agent(),
        KnowledgeAction.read,
        KnowledgeTarget.note('n', 'ordinary'),
      ),
      isTrue,
    );
  });

  test('a formerly public historical path cannot bypass current private policy',
      () async {
    await authorization.putFolderPolicy(
      operator,
      'private',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    expect(
      () => authorization.requireHistoricalRead(
        agent(),
        'n',
        'public',
        'private',
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
  });

  test('current public policy does not open a retained private location',
      () async {
    await authorization.putFolderPolicy(
      operator,
      'private',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    expect(
      () => authorization.requireHistoricalRead(
        agent(),
        'n',
        'private',
        'public',
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
  });

  test('accepted history faults block policy publication', () async {
    final faulted = NoteAuthorizationService(
      store: store,
      beforeMutation: () async {
        throw StateError('restart required');
      },
    );
    await expectLater(
      faulted.putFolderPolicy(
        operator,
        '',
        KnowledgePolicyPatch(curated: true),
      ),
      throwsStateError,
    );
    expect(store.revision, 0);
    expect(store.file.existsSync(), isFalse);
  });

  test('ordinary notes retain scoped agent writes', () {
    final target = KnowledgeTarget.note('note-1', 'ordinary');
    expect(authorization.allows(agent(), KnowledgeAction.edit, target), isTrue);
  });

  test('curated agents propose even when explicitly granted edit scope',
      () async {
    await authorization.putFolderPolicy(
      operator,
      'institution',
      KnowledgePolicyPatch(curated: true),
    );
    final principal = agent(
      scopes: {
        'notes:read',
        'notes:write',
        'knowledge:propose',
        'knowledge:edit',
      },
    );
    final target = KnowledgeTarget.note('note-1', 'institution');
    expect(
      authorization.allows(principal, KnowledgeAction.propose, target),
      isTrue,
    );
    expect(
      authorization.allows(principal, KnowledgeAction.edit, target),
      isFalse,
    );
  });

  test('folder and note fields inherit independently', () async {
    await authorization.putFolderPolicy(
      operator,
      '',
      KnowledgePolicyPatch(
        curated: true,
        access: {
          KnowledgeAction.read: {'agent:worker'},
          KnowledgeAction.propose: {'agent:worker'},
        },
      ),
    );
    await authorization.putFolderPolicy(
      operator,
      'team',
      KnowledgePolicyPatch(access: {KnowledgeAction.propose: {}}),
    );
    final target = KnowledgeTarget.note('note-1', 'team/child');
    await authorization.putNotePolicy(
      operator,
      target,
      KnowledgePolicyPatch(
        access: {
          KnowledgeAction.propose: {'agent:worker'},
        },
      ),
    );
    final resolved = store.effective(target);
    expect(resolved.curated, isTrue);
    expect(authorization.allows(agent(), KnowledgeAction.read, target), isTrue);
    expect(
      authorization.allows(agent(), KnowledgeAction.propose, target),
      isTrue,
    );
  });

  test('explicit empty access denies inherited grants', () async {
    await authorization.putFolderPolicy(
      operator,
      'private',
      KnowledgePolicyPatch(access: {KnowledgeAction.read: {}}),
    );
    expect(
      authorization.allows(
        agent(),
        KnowledgeAction.read,
        KnowledgeTarget.note('n', 'private'),
      ),
      isFalse,
    );
  });

  test('wildcard access still requires the exact capability', () async {
    await authorization.putFolderPolicy(
      operator,
      'institution',
      KnowledgePolicyPatch(
        curated: true,
        access: {
          KnowledgeAction.edit: {'*'},
        },
      ),
    );
    final principal = KnowledgePrincipal.oauth(
      grantId: 'writer',
      scopes: {'notes:read', 'notes:write', 'vaults:manage'},
    );
    final target = KnowledgeTarget.note('n', 'institution');
    expect(
      authorization.allows(principal, KnowledgeAction.edit, target),
      isFalse,
    );
    expect(
      authorization.allows(principal, KnowledgeAction.purge, target),
      isFalse,
    );
  });

  test('operator-approved human edit and review are distinct', () async {
    await authorization.putFolderPolicy(
      operator,
      'institution',
      KnowledgePolicyPatch(curated: true),
    );
    final reviewer = KnowledgePrincipal.oauth(
      grantId: 'human',
      scopes: {'notes:read', 'knowledge:review'},
    );
    final target = KnowledgeTarget.note('n', 'institution');
    expect(
      authorization.allows(reviewer, KnowledgeAction.review, target),
      isTrue,
    );
    expect(
      authorization.allows(reviewer, KnowledgeAction.edit, target),
      isFalse,
    );
  });

  test('agent review and policy scopes cannot supply human authority',
      () async {
    final principal = agent(
      scopes: {
        'notes:read',
        'notes:write',
        'knowledge:review',
        'knowledge:policy',
      },
    );
    final target = KnowledgeTarget.note('n', 'institution');
    expect(
      authorization.allows(principal, KnowledgeAction.review, target),
      isFalse,
    );
    expect(
      authorization.putFolderPolicy(
        principal,
        '',
        KnowledgePolicyPatch(curated: false),
      ),
      throwsA(isA<KnowledgeAccessDeniedException>()),
    );
  });

  test('policy grants persist with stable identities across restarts',
      () async {
    await authorization.putFolderPolicy(
      operator,
      'team',
      KnowledgePolicyPatch(
        curated: true,
        access: {
          KnowledgeAction.read: {'agent:worker'},
        },
      ),
    );
    final reopened = KnowledgePolicyStore(file: store.file);
    await reopened.load();
    addTearDown(reopened.dispose);
    final effective = reopened.effective(KnowledgeTarget.note('n', 'team'));
    expect(effective.curated, isTrue);
    expect(effective.access[KnowledgeAction.read], {'agent:worker'});
    expect(reopened.revision, store.revision);
  });

  test('malformed persisted policy cannot silently open access', () async {
    await store.file.writeAsString('{"version":1,"folders":{"secret":true}}');
    final reopened = KnowledgePolicyStore(file: store.file);
    addTearDown(reopened.dispose);
    expect(reopened.load(), throwsA(isA<FormatException>()));
  });

  test('note permission response exposes only the callers effective actions',
      () async {
    await authorization.putFolderPolicy(
      operator,
      'institution',
      KnowledgePolicyPatch(curated: true),
    );
    final response = authorization.permissions(
      agent(),
      KnowledgeTarget.note('n', 'institution'),
    );
    expect(response['curated'], isTrue);
    expect(response['allowed_actions'], ['read', 'propose']);
    expect(response['requires_human_approval'], isTrue);
    expect(response.containsKey('access'), isFalse);
  });
  test('vault management cannot authorize curated edit review policy or purge',
      () async {
    final principal = KnowledgePrincipal.oauth(
      grantId: 'oidc',
      scopes: {'notes:read', 'notes:write', 'vaults:manage'},
    );
    final target = KnowledgeTarget.note('ACTUAL-ID', 'curated');
    await authorization.putNotePolicy(
      operator,
      target,
      KnowledgePolicyPatch(curated: true),
    );
    expect(authorization.allows(principal, KnowledgeAction.read, target), true);
    for (final action in [
      KnowledgeAction.edit,
      KnowledgeAction.review,
      KnowledgeAction.policy,
      KnowledgeAction.purge,
    ]) {
      expect(authorization.allows(principal, action, target), false);
    }
    expect(target.noteId, 'ACTUAL-ID');
  });

  test('designation replay preserves ACLs and applies once', () async {
    final target = KnowledgeTarget.note('NOTE-ID', 'ordinary');
    await authorization.putNotePolicy(
      operator,
      target,
      KnowledgePolicyPatch(
        access: {
          KnowledgeAction.read: {'oauth:owner'},
        },
      ),
    );
    final delta = <String, dynamic>{
      'id': 'NOTE-ID',
      'path': 'ordinary',
      'approval': 'human',
      'operation_id': 'proposal:1',
    };
    await store.replayAcceptedNoteDesignation(delta);
    final revision = store.revision;
    await store.replayAcceptedNoteDesignation(delta);
    expect(store.revision, revision);
    expect(store.effective(target).curated, true);
    expect(
      store.effective(target).access[KnowledgeAction.read],
      {'oauth:owner'},
    );
    await expectLater(
      store.replayAcceptedNoteDesignation({...delta, 'path': 'different'}),
      throwsStateError,
    );
    final reopened = KnowledgePolicyStore(file: store.file);
    await reopened.load();
    addTearDown(reopened.dispose);
    await reopened.replayAcceptedNoteDesignation(delta);
    expect(reopened.revision, revision);
  });
}
