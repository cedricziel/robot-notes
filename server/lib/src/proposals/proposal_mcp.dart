import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/mcp/tool_results.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/proposals/block_compiler.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/storage.dart';

const _string = {'type': 'string', 'minLength': 1};
const _revision = {'type': 'integer', 'minimum': 1};
const _operations = {'type': 'array', 'minItems': 1};
const _evidence = {'type': 'array'};
const _identity = {'id': _string, 'proposal_id': _string};
const _candidate = {
  'base_version': _revision,
  'operations': _operations,
  'evidence_refs': _evidence,
};
const _draft = {
  'path': {'type': 'string'},
  'title': _string,
  'content': {'type': 'string'},
  'properties': {'type': 'object'},
  'evidence_refs': _evidence,
  'curated_intent': {'type': 'boolean'},
};
const _comment = {
  'record_revision': _revision,
  'body': _string,
  'block_id': _string,
  'block_revision': _revision,
  'reply_to': _string,
};

/// MCP exposes pending review separately from normal accepted retrieval tools.
List<McpTool> proposalMcpTools(ProposalService service) {
  McpTool tool(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
    Future<Map<String, Object?>> Function(
      Map<String, dynamic> input,
      String actor,
    ) body, {
    bool readOnly = false,
  }) =>
      McpTool(
        name: name,
        description: description,
        inputSchema: {
          'type': 'object',
          'properties': properties,
          'required': required,
        },
        annotations: {
          'readOnlyHint': readOnly,
          'destructiveHint': false,
          'openWorldHint': false,
        },
        requiresWrite: false,
        handler: (args, principal) =>
            withKnowledgePrincipal(principal.knowledgePrincipal, () async {
          try {
            return toolOk(await body({...args}, principal.actor));
          } on KnowledgeAccessDeniedException {
            return toolFail('forbidden');
          } on ProposalRecordConflictException catch (error) {
            return toolFail(error.reason);
          } on ProposalBlockConflictException catch (error) {
            return toolFail(error.reason);
          } on ProposalEvidenceException catch (error) {
            return toolFail(error.reason);
          } on NoteNotFoundException {
            return toolFail('not_found');
          } on BlockMapUnavailableException catch (error) {
            return toolFail(
              error.stale ? 'block_map_stale' : 'block_map_unavailable',
            );
          } on PathConflictException {
            return toolFail('path_conflict');
          } on PropertyValidationException {
            return toolFail('invalid_properties');
          } on FormatException {
            return toolFail('bad_request');
          }
        }),
      );

  String id(Map<String, dynamic> input) => input.remove('id') as String;
  String proposalId(Map<String, dynamic> input) =>
      input.remove('proposal_id') as String;
  Map<String, Object?> result(ProposalRecord record) =>
      {...record.summary(), 'accepted': record.state == 'accepted'};

  return [
    tool(
      'get_note_blocks',
      'Read exact accepted Markdown, stable block IDs, '
          'UTF-16 spans, and active source links atomically.',
      {'id': _string, 'version': _revision},
      ['id'],
      (input, _) => service.acceptedBlocks(
        id(input),
        version: input['version'] as int?,
      ),
      readOnly: true,
    ),
    tool(
      'list_note_proposals',
      'List readable review proposals in this vault, '
          'including drafts. Filter state=accepted for audit.',
      {
        'id': _string,
        'state': _string,
        'include_terminal': {'type': 'boolean'},
      },
      [],
      (input, _) async => {
        'items': await service.list(
          noteId: input['id'] as String?,
          state: input['state'] as String?,
          includeTerminal: input['include_terminal'] as bool? ?? false,
        ),
      },
      readOnly: true,
    ),
    tool(
      'get_note_proposal',
      'Inspect pending candidates, retained review '
          'activity, draft targets, and your own allowed actions.',
      _identity,
      ['id', 'proposal_id'],
      (input, _) => service.inspect(id(input), proposalId(input)),
      readOnly: true,
    ),
    tool(
      'propose_note_update',
      'Propose atomic block changes to accepted '
          'Markdown. Text edits require human review; source attachments '
          'may qualify under explicit automatic policy.',
      {'id': _string, ..._candidate, 'idempotency_key': _string},
      ['id', 'base_version', 'operations', 'idempotency_key'],
      (input, actor) async => result(
        await service.submit(
          id(input),
          input,
          actor: actor,
        ),
      ),
    ),
    tool(
        'propose_note_create',
        'Reserve a new-note draft for review without '
            'creating accepted Markdown. Institutional intent defaults true.',
        {..._draft, 'idempotency_key': _string},
        ['title', 'content', 'idempotency_key'], (input, actor) async {
      input.putIfAbsent('path', () => '');
      return result(await service.submitNew(input, actor: actor));
    }),
    tool(
      'amend_note_proposal',
      'Amend a candidate with explicit proposal and '
          'record revisions; prior candidates and comments remain retained.',
      {
        ..._identity,
        ..._candidate,
        ..._draft,
        'proposal_revision': _revision,
        'record_revision': _revision,
      },
      ['id', 'proposal_id', 'proposal_revision', 'record_revision'],
      (input, actor) async => result(
        await service.amend(
          id(input),
          proposalId(input),
          input,
          actor: actor,
        ),
      ),
    ),
    tool(
      'comment_note_proposal',
      'Append a review comment or reply. '
          'Requires read plus propose or trusted human review rights.',
      {..._identity, ..._comment},
      ['id', 'proposal_id', 'record_revision', 'body'],
      (input, actor) async => result(
        await service.comment(
          id(input),
          proposalId(input),
          input,
          actor: actor,
        ),
      ),
    ),
    tool(
      'review_note_proposal',
      'Approve, deny, or request changes with record '
          'CAS. Final decisions require trusted human review authority.',
      {
        ..._identity,
        'decision': {
          'type': 'string',
          'enum': ['approve', 'deny', 'request_changes'],
        },
        'record_revision': _revision,
        'comment': _string,
      },
      ['id', 'proposal_id', 'decision', 'record_revision'],
      (input, actor) async => result(
        await service.decide(
          id(input),
          proposalId(input),
          input,
          actor: actor,
        ),
      ),
    ),
    tool(
      'get_note_comments',
      'Read immutable accepted-block comment threads '
          'and current anchor status without a proposal wrapper.',
      {'id': _string},
      ['id'],
      (input, _) => service.acceptedComments(id(input)),
      readOnly: true,
    ),
    tool(
      'add_note_comment',
      'Append an accepted-block comment or immutable '
          'thread reply with exact block and record CAS.',
      {
        'id': _string,
        ..._comment,
        'record_revision': {'type': 'integer', 'minimum': 0},
      },
      ['id', 'record_revision', 'body'],
      (input, actor) => service.commentAccepted(id(input), input, actor: actor),
    ),
  ];
}
