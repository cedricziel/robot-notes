import 'dart:async';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/knowledge_reads.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';
import 'package:test/test.dart' as tests;

/// Existing isolated adapter fixtures explicitly run as a trusted operator.
void authorizedTest(
  Object description,
  FutureOr<void> Function() body, {
  String? testOn,
  tests.Timeout? timeout,
  dynamic skip,
  dynamic tags,
  Map<String, dynamic>? onPlatform,
  int? retry,
}) =>
    tests.test(
      description,
      () =>
          withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
        await body();
      }),
      testOn: testOn,
      timeout: timeout,
      skip: skip,
      tags: tags,
      onPlatform: onPlatform,
      retry: retry,
    );

/// Setup writes use the same explicitly trusted fixture context as the test.
void authorizedSetUp(FutureOr<void> Function() body) => tests.setUp(
      () =>
          withKnowledgePrincipal(const KnowledgePrincipal.operator(), () async {
        await body();
      }),
    );

/// Mock route contexts represent a policy-free operator vault.
final fixtureAuthorization =
    NoteAuthorizationService(store: KnowledgePolicyStore.memory());

/// Operator read answers for isolated route tests.
final fixtureReads = _OperatorReads();

class _OperatorReads extends KnowledgeReadService {
  _OperatorReads()
      : super(authorization: fixtureAuthorization, metaIndex: MetaIndex());
  @override
  Set<String>? get allowedIds => null;
  @override
  bool canReadId(String id) => true;
  @override
  bool canReadFolder(String path) => true;
  @override
  bool canReadSummary(NoteSummary summary) => true;
  @override
  Future<KnowledgeTarget> resolveTarget(String id) async =>
      KnowledgeTarget.note(id, '');
  @override
  Future<void> requireFile(String relativePath) async {}
}
