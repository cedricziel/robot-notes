import 'dart:async';

import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:test/test.dart';

void main() {
  test('missing request context has no authority', () {
    expect(currentKnowledgePrincipal.kind, KnowledgePrincipalKind.unidentified);
    expect(currentKnowledgePrincipal.hasScope('notes:write'), isFalse);
  });

  test('overlapping requests retain their own recorded identities', () async {
    final firstEntered = Completer<void>();
    final secondEntered = Completer<void>();
    final release = Completer<void>();
    final first = withKnowledgePrincipal(
      KnowledgePrincipal.agent(credentialId: 'first', scopes: {'notes:write'}),
      () async {
        firstEntered.complete();
        await secondEntered.future;
        await release.future;
        return currentKnowledgePrincipal.id;
      },
    );
    await firstEntered.future;
    final second = withKnowledgePrincipal(
      KnowledgePrincipal.agent(credentialId: 'second', scopes: {'notes:read'}),
      () async {
        secondEntered.complete();
        release.complete();
        return currentKnowledgePrincipal.id;
      },
    );
    expect(await Future.wait([first, second]), ['agent:first', 'agent:second']);
    expect(currentKnowledgePrincipal.kind, KnowledgePrincipalKind.unidentified);
  });

  test('deferred work cannot retain an expired request identity', () async {
    final trigger = Completer<void>();
    late Future<KnowledgePrincipalKind> deferred;
    await withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
      deferred = trigger.future.then((_) => currentKnowledgePrincipal.kind);
    });
    trigger.complete();
    expect(await deferred, KnowledgePrincipalKind.unidentified);
  });
}
