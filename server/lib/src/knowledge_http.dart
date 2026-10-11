import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/storage.dart';

final _noteRequest = RegExp(r'^/(notes|databases)/([^/]+)(?:/(.*))?$');
const _noteCollections = {
  'tree',
  'files',
  'file-uploads',
  'permissions',
  'proposals',
};

/// Gates existing-note access before handlers inspect locks or validation data.
Future<void> guardKnowledgeRequest(RequestContext context, AppDeps deps) async {
  final match = _noteRequest.firstMatch(context.request.uri.path);
  if (match == null || _noteCollections.contains(match.group(2))) return;
  final id = match.group(2)!;
  final rest = match.group(3) ?? '';
  final principal = currentKnowledgePrincipal;
  if (principal.kind == KnowledgePrincipalKind.unidentified) {
    throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
  }
  final KnowledgeTarget target;
  try {
    target = await deps.noteWriteService.knowledgeTarget(id);
  } on NoteNotFoundException {
    return;
  }
  final authorization = deps.authorization;
  void requireAction(KnowledgeAction action) =>
      authorization.require(principal, action, target);
  requireAction(KnowledgeAction.read);
  final method = context.request.method;
  if (method == HttpMethod.get ||
      method == HttpMethod.head ||
      method == HttpMethod.options) {
    return;
  }
  if (rest == 'query' ||
      rest == 'rows' ||
      rest == 'comments' ||
      rest.startsWith('proposals')) {
    return;
  }
  requireAction(
    rest == 'history' && method == HttpMethod.delete
        ? KnowledgeAction.purge
        : KnowledgeAction.edit,
  );
}
