import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge/api.dart';
import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge/operation_scopes.dart';
import 'package:server/src/knowledge/query_service.dart';
import 'package:server/src/knowledge/runtime.dart';
import 'package:server/src/knowledge/source_store.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/storage.dart';

({int status, String code}) _failure(Object error, String operation) {
  if (error is KnowledgeCapabilityUnavailable) {
    return (status: 501, code: 'unsupported_capability');
  }
  if (error is KnowledgeAccessDeniedException) {
    final hidden = error.action == KnowledgeAction.read ||
        knowledgeReadOperations.contains(operation);
    return (
      status: hidden ? 404 : 403,
      code: hidden ? 'not_found' : 'forbidden'
    );
  }
  if (error is SourceUnavailable ||
      error is NoteNotFoundException ||
      error is FileSystemException) {
    return (status: 404, code: 'not_found');
  }
  if (error is KnowledgeCursorStale) return (status: 409, code: 'cursor_stale');
  if (error is SourceDeliveryConflict) {
    return (status: 409, code: 'idempotency_conflict');
  }
  if (error is ProposalRecordConflictException) {
    return (status: 409, code: error.reason);
  }
  if (error is KnowledgeExtractionFailure) {
    return (status: 409, code: error.code);
  }
  if (error is FormatException || error is TypeError) {
    return (status: 400, code: 'invalid_params');
  }
  if (error is PathConflictException) {
    return (status: 409, code: 'path_conflict');
  }
  return (status: 500, code: 'knowledge_operation_failed');
}

/// Shared selected-vault HTTP dispatch; request labels never authorize
/// operations.
Future<Response> knowledgeOperationRequest(
  RequestContext context,
  String operation,
) async {
  final capability = operation == 'capabilities';
  if (context.request.method !=
      (capability ? HttpMethod.get : HttpMethod.post)) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'method_not_allowed'},
    );
  }
  if (!capability && !knowledgeOperationSchemas.containsKey(operation)) {
    return Response.json(statusCode: 404, body: {'error': 'not_found'});
  }
  try {
    final identity = context.read<RestPrincipal>().knowledgePrincipal;
    final principal =
        context.request.headers['x-robot-notes-agent']?.trim().toLowerCase() ==
                'true'
            ? identity.withAgentOrigin()
            : identity;
    return await withKnowledgePrincipal(principal, () async {
      final raw =
          capability ? <String, Object?>{} : await context.request.json();
      if (raw is! Map<String, Object?>) {
        throw const FormatException('Expected request object');
      }
      final result = await KnowledgeApi(context.read<KnowledgeRuntime>())
          .call(operation, raw);
      return Response.json(body: result);
    });
  } on Object catch (error) {
    final failure = _failure(error, operation);
    return Response.json(
      statusCode: failure.status,
      body: {'error': failure.code},
    );
  }
}

/// Downloads original bytes only after selected-vault source authorization.
Future<Response> knowledgeSourceBytesRequest(
  RequestContext context,
  String sourceId,
  String revision,
) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'method_not_allowed'},
    );
  }
  try {
    final identity = context.read<RestPrincipal>().knowledgePrincipal;
    return await withKnowledgePrincipal(identity, () async {
      final runtime = context.read<KnowledgeRuntime>();
      if (!runtime.enabled) throw KnowledgeCapabilityUnavailable();
      final bytes = await runtime.sources.inspect(sourceId, revision);
      return Response.bytes(
        body: bytes,
        headers: {
          'content-type': 'application/octet-stream',
          'content-disposition': 'attachment; filename="source.bin"',
          'cache-control': 'no-store',
          'x-content-type-options': 'nosniff',
        },
      );
    });
  } on Object catch (error) {
    final failure = _failure(error, 'inspect_source');
    return Response.json(
      statusCode: failure.status,
      body: {'error': failure.code},
    );
  }
}

/// MCP uses the same schemas and operation implementation as HTTP.
List<McpTool> knowledgeMcpTools(KnowledgeRuntime runtime) => [
      for (final entry in knowledgeOperationSchemas.entries)
        McpTool(
          name: entry.key,
          description: _descriptions[entry.key]!,
          inputSchema: entry.value,
          annotations: {
            'readOnlyHint': knowledgeReadOperations.contains(entry.key) ||
                entry.key == 'validate_knowledge_candidate',
            'idempotentHint': entry.key.startsWith('propose_'),
            'destructiveHint': entry.key.startsWith('review_') ||
                entry.key.startsWith('purge_') ||
                entry.key == 'configure_source_scope',
          },
          requiresWrite: false,
          requiredScope: knowledgeOperationScope(entry.key),
          handler: (args, principal) =>
              withKnowledgePrincipal(principal.knowledgePrincipal, () async {
            try {
              return toolOk(
                await KnowledgeApi(runtime).call(entry.key, args),
              );
            } on Object catch (error) {
              return toolFail(_failure(error, entry.key).code);
            }
          }),
        ),
    ];

const _descriptions = {
  'purge_source_revision': 'Purge authorized original source bytes and cancel '
      'dependent extraction work. Requires human purge authority. '
      'Consumed delivery keys remain tombstoned.',
  'reextract_source': 'Explicitly replay an authorized immutable source with '
      'a distinct generation. Requires human policy authority and enabled '
      'extraction. Retried generation keys retain job identity.',
  'preview_knowledge_type_upgrade':
      'Preview readable accepted entries affected by a '
          'proposed pinned type revision, including expected '
          'revisions and structural diagnostics. No entries '
          'migrate until an explicit reviewed typed update group '
          'succeeds.',
  'list_knowledge_types': 'List accepted pinned types and guidance. Optional '
      'namespace, limit 1-200, and opaque cursor; pending '
      'definitions are excluded. Requires read access.',
  'get_knowledge_type': 'Read an accepted type by stable type_id and optional '
      'pinned version. Returns inherited constraints and '
      'authoring guidance; specify version if ambiguous.',
  'query_knowledge': 'Query readable accepted typed entries. Filter pinned '
      'types, conjunctive primitive properties and named '
      'relations, sort, and paginate. Outgoing traversal '
      'max_depth 0-2 and max_nodes 1-200 returns truncation. '
      'Pending text is excluded.',
  'inspect_source': 'Inspect an authorized immutable '
      'source_id/source_revision and optional whole_document '
      'or Unicode-scalar text_range locator. Text excerpts '
      'are bounded to 16000 scalars. Missing and inaccessible '
      'sources are indistinguishable.',
  'validate_knowledge_candidate':
      'Read-only complete-state validation of atomic '
          'create/update operations. Creates use local_ref; '
          'updates use id and expected_revision. Includes pinned '
          'types, property sets/unsets, and named relations with '
          'stable IDs or local_ref objects. Requires proposal and '
          'referenced-input read authority.',
  'propose_knowledge': 'Submit a focused atomic candidate group with '
      'idempotency_key. Returns proposal identity, revision, '
      'pending state, and diagnostics without creating '
      'accepted placeholders. Requires proposal authority; '
      'metadata is untrusted review context.',
  'get_knowledge_proposal':
      'Inspect an authorized typed proposal by proposal_id, '
          'including retained candidates, diagnostics, evidence, '
          'and review events. Pending text is untrusted and is '
          'not accepted recall.',
  'amend_knowledge_proposal': 'Replace a pending typed candidate with '
      'proposal_revision and record_revision CAS plus a '
      'stable idempotency_key. Old candidate versions remain '
      'retained; stale review fails.',
  'review_knowledge_proposal':
      'Human-only acceptance of a fresh complete group. '
          'Requires review authority, and policy authority when '
          'creating curated designations. Agent credentials '
          'cannot accept even with elevated scopes.',
  'configure_source_scope': 'Human-only source scope policy. Configure exact '
      'capture_adapters, qualified principal IDs, independent '
      'extraction_enabled, and '
      'session_end/completed_turn/both trigger. Capture and '
      'extraction default off.',
  'ingest_source': 'Ingest original bytes as content_base64 with exact '
      'adapter/event_id, stable scope_id, media_type, and '
      'optional observed_at. Automatic observations require '
      'explicit adapter capture opt-in. Retries preserve '
      'revisions; changed payload or scope conflicts. Source '
      'text never becomes accepted knowledge through '
      'ingestion.',
  'extraction_health': 'Read authorized extraction job states, retry '
      'categories, source references, and proposal receipts '
      'without source text or model credentials.',
  'propose_knowledge_types':
      'Submit filesystem Markdown definition, vocabulary, or '
          'adoption candidates as a documents map with '
          'idempotency_key. Uses separate type review; never '
          'activates definitions directly.',
  'get_knowledge_type_proposal':
      'Read authorized retained type candidates and versions '
          'by proposal_id. Candidate edits do not change accepted '
          'validation.',
  'review_knowledge_type_proposal':
      'Human-only atomic activation of a fresh type candidate '
          'group under record_revision CAS. Revalidates pinned '
          'inheritance, policy, artifacts, and complete adoption '
          'membership.',
  'preview_schema_org': 'Decode a pinned published Schema.org JSON-LD artifact '
      'with release, versioned artifact_source, '
      'content_base64, and optional expected sha256. Returns '
      'identities and unsupported semantics without '
      'activation.',
  'propose_schema_org': 'Submit the complete pinned vocabulary, retained '
      'artifact, adoption manifest, and initial local '
      'definitions through type review. Supply explicit '
      'unsupported_dispositions; review is required for '
      'activation.',
};
