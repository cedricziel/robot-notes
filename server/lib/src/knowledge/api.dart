import 'dart:convert';

import 'package:server/src/knowledge/extraction_model.dart';
import 'package:server/src/knowledge/runtime.dart';
import 'package:server/src/knowledge/schema_org_import.dart';
import 'package:server/src/knowledge/type_definition.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/storage.dart';

/// New operations remain unavailable until explicit feature activation.
class KnowledgeCapabilityUnavailable implements Exception {}

/// Adapter-neutral contracts shared by REST, MCP, and the extraction services.
class KnowledgeApi {
  /// Uses one selected-vault runtime and its current authenticated context.
  KnowledgeApi(this.runtime);

  /// Selected vault, never inferred from actor display labels.
  final KnowledgeRuntime runtime;

  String _string(Map<String, Object?> input, String key) {
    final value = input[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be nonempty text');
    }
    return value;
  }

  int _integer(Map<String, Object?> input, String key) {
    final value = input[key];
    if (value is! int || value < 1) {
      throw FormatException('$key must be a positive integer');
    }
    return value;
  }

  List<Object?> _list(Object? value) {
    if (value is! List<Object?>) throw const FormatException('Expected list');
    return value;
  }

  Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected object');
    }
    return value;
  }

  /// Static availability never grants read, proposal, or review authority.
  Map<String, Object?> capabilities() => {
        'knowledge_contract_version': 1,
        'principal_id': currentKnowledgePrincipal.id,
        'vault_id': runtime.authorization.vaultId,
        'enabled': runtime.enabled,
        'source_capture': runtime.enabled,
        'background_extraction':
            runtime.enabled && runtime.extractionConfig != null,
        'operations': runtime.enabled
            ? knowledgeOperationSchemas.keys.toList()
            : <String>[],
      };

  Future<ProposalRecord> _record(String id) async {
    for (final record in await runtime.storage.proposalRecords()) {
      if (record.id == id &&
          record.current.candidate['kind'] == 'typed_knowledge') {
        return runtime.proposals.inspect(record.noteId, id);
      }
    }
    throw NoteNotFoundException(id);
  }

  Map<String, Object?> _result(ProposalRecord record) => {
        ...record.summary(),
        'accepted': record.state == 'accepted',
        'diagnostics': record.current.candidate['diagnostics'] ?? <Object?>[],
      };

  /// Executes a declared operation with identical domain checks across
  /// adapters.
  Future<Map<String, Object?>> call(
    String operation,
    Map<String, Object?> input,
  ) async {
    final principal = currentKnowledgePrincipal;
    if (!principal.canAccessVault(runtime.authorization.vaultId) ||
        !principal.hasScope('notes:read')) {
      throw const KnowledgeAccessDeniedException(KnowledgeAction.read);
    }
    if (operation == 'capabilities') return capabilities();
    if (!runtime.enabled) throw KnowledgeCapabilityUnavailable();
    final schema = knowledgeOperationSchemas[operation];
    if (schema == null) {
      throw const FormatException('Unknown knowledge operation');
    }
    final properties = schema['properties']! as Map<String, Object?>;
    if (!input.keys.every(properties.containsKey)) {
      throw const FormatException('Unsupported operation field');
    }
    for (final required in schema['required']! as List<String>) {
      if (!input.containsKey(required)) {
        throw FormatException('Missing $required');
      }
    }
    switch (operation) {
      case 'list_knowledge_types':
        final namespace = input['namespace'] as String?;
        final limit = input['limit'] as int? ?? 50;
        if (limit < 1 || limit > 200) {
          throw const FormatException('Type limit must be 1 to 200');
        }
        final definitions = (await runtime.types.definitions())
            .where((type) => namespace == null || type.id.startsWith(namespace))
            .toList()
          ..sort((a, b) => a.reference.key.compareTo(b.reference.key));
        final revision = '${await runtime.types.generation()}:'
            '${runtime.authorization.store.revision}';
        var offset = 0;
        if (input['cursor'] != null) {
          final cursor = jsonDecode(
            utf8.decode(base64Url.decode(input['cursor']! as String)),
          ) as Map<String, dynamic>;
          if (cursor['revision'] != revision ||
              cursor['namespace'] != namespace ||
              cursor['principal'] != principal.id ||
              cursor['limit'] != limit) {
            throw const ProposalRecordConflictException('cursor_stale');
          }
          offset = cursor['offset'] as int;
          if (offset < 0 || offset > definitions.length) {
            throw const FormatException('Invalid type cursor');
          }
        }
        final page = definitions.skip(offset).take(limit).toList();
        return {
          'items': page.map((type) => type.toMetadata()).toList(),
          'next_cursor': offset + page.length < definitions.length
              ? base64Url.encode(
                  utf8.encode(
                    jsonEncode({
                      'revision': revision,
                      'namespace': namespace,
                      'principal': principal.id,
                      'limit': limit,
                      'offset': offset + page.length,
                    }),
                  ),
                )
              : null,
        };
      case 'get_knowledge_type':
        final id = _string(input, 'type_id');
        final definitions = await runtime.types.definitions();
        final matches = definitions
            .where(
              (type) =>
                  type.id == id &&
                  (input['version'] == null ||
                      type.reference.version == input['version']),
            )
            .toList();
        if (matches.isEmpty) throw NoteNotFoundException(id);
        if (matches.length > 1) {
          throw const FormatException('Specify a pinned type version');
        }
        return KnowledgeTypeResolver(definitions)
            .resolve(matches.single.reference)
            .toMetadata();
      case 'query_knowledge':
        return runtime.queries.query(input);
      case 'inspect_source':
        final id = _string(input, 'source_id');
        final revision = _string(input, 'source_revision');
        final metadata = runtime.sources.descriptor(id, revision);
        final locator = _object(input['locator'] ?? {'kind': 'whole_document'});
        final text = await runtime.sources.passage(id, revision, locator);
        return {
          'source': metadata.toJson(),
          'blob_ref': {
            'vault_id': runtime.authorization.vaultId,
            'url': '/knowledge/sources/$id/$revision',
          },
          'locator': locator,
          'text': text.runes.length > 16000
              ? String.fromCharCodes(text.runes.take(16000))
              : text,
          'truncated': text.runes.length > 16000,
        };
      case 'validate_knowledge_candidate':
        return runtime.proposals.validate(_list(input['operations']));
      case 'propose_knowledge':
        return _result(
          await runtime.proposals.propose(
            _list(input['operations']),
            idempotencyKey: _string(input, 'idempotency_key'),
            metadata: _object(input['metadata'] ?? const <String, Object?>{}),
          ),
        );
      case 'get_knowledge_proposal':
        final record = await _record(_string(input, 'proposal_id'));
        return {
          ..._result(record),
          'candidate': record.current.candidate,
          'versions':
              record.versions.map((version) => version.toJson()).toList(),
          'events': record.events,
        };
      case 'amend_knowledge_proposal':
        final record = await _record(_string(input, 'proposal_id'));
        return _result(
          await runtime.proposals.amend(
            record.noteId,
            record.id,
            _list(input['operations']),
            idempotencyKey: _string(input, 'idempotency_key'),
            expectedRecordRevision: _integer(input, 'record_revision'),
            expectedProposalRevision: _integer(input, 'proposal_revision'),
          ),
        );
      case 'review_knowledge_proposal':
        final record = await _record(_string(input, 'proposal_id'));
        if (input['decision'] != null && input['decision'] != 'approve') {
          return _result(
            await runtime.proposals.decide(
              record.noteId,
              record.id,
              decision: _string(input, 'decision'),
              expectedRecordRevision: _integer(input, 'record_revision'),
            ),
          );
        }
        return _result(
          await runtime.proposals.accept(
            record.noteId,
            record.id,
            expectedRecordRevision: _integer(input, 'record_revision'),
          ),
        );
      case 'configure_source_scope':
        final extractionEnabled = input['extraction_enabled'] as bool? ?? false;
        if (extractionEnabled && runtime.worker == null) {
          throw const KnowledgeExtractionFailure('extractor_unavailable');
        }
        runtime.worker;
        await runtime.sources.configureScope(
          _string(input, 'scope_id'),
          captureAdapters:
              _list(input['capture_adapters']).cast<String>().toSet(),
          principals: _list(input['principals']).cast<String>().toSet(),
          extractionEnabled: extractionEnabled,
          trigger: input['trigger'] as String? ?? 'session_end',
        );
        return {
          'scope': runtime.sources.scopeSettings(_string(input, 'scope_id')),
        };
      case 'ingest_source':
        runtime.worker;
        final source = await runtime.sources.ingest(
          adapter: _string(input, 'adapter'),
          eventId: _string(input, 'event_id'),
          scopeId: _string(input, 'scope_id'),
          bytes: base64Decode(_string(input, 'content_base64')),
          mediaType: _string(input, 'media_type'),
          automatic: input['automatic'] as bool? ?? false,
          observedAt: input['observed_at'] == null
              ? null
              : DateTime.parse(input['observed_at']! as String),
          sourceId: input['source_id'] as String?,
          observationKind: input['observation_kind'] as String? ?? 'import',
          conversationId: input['conversation_id'] as String?,
        );
        return {'source': source.toJson()};
      case 'purge_source_revision':
        await runtime.sources.purge(
          _string(input, 'source_id'),
          _string(input, 'source_revision'),
        );
        return {'purged': true};
      case 'reextract_source':
        final worker = runtime.worker;
        if (worker == null) throw KnowledgeCapabilityUnavailable();
        return {
          'job_id': await worker.reextract(
            _string(input, 'source_id'),
            _string(input, 'source_revision'),
            generation: _string(input, 'generation'),
          ),
        };
      case 'extraction_health':
        if (runtime.extractionConfig == null) {
          return {'jobs': <Object?>[], 'extractor_configured': false};
        }
        final visible = <Map<String, Object?>>[];
        for (final job in runtime.jobs.summaries()) {
          try {
            runtime.sources.scopeSettings(job['scope_id']! as String);
            final receipts = <Object?>[];
            for (final raw in job['proposals']! as List<Object?>) {
              final receipt = _object(raw);
              try {
                await _record(receipt['proposal_id']! as String);
                receipts.add(receipt);
              } on KnowledgeAccessDeniedException {
                continue;
              } on NoteNotFoundException {
                continue;
              }
            }
            visible.add({...job, 'proposals': receipts});
          } on KnowledgeAccessDeniedException {
            continue;
          }
        }
        return {'jobs': visible, 'extractor_configured': true};
      case 'preview_knowledge_type_upgrade':
        return runtime.proposals.previewTypeUpgrade(
          KnowledgeTypeDefinition.fromMetadata(input['definition']),
        );
      case 'propose_knowledge_types':
        final documents = _object(input['documents']).cast<String, String>();
        return _result(
          await runtime.typeReview.propose(
            documents,
            idempotencyKey: _string(input, 'idempotency_key'),
          ),
        );
      case 'get_knowledge_type_proposal':
        final record =
            await runtime.typeReview.inspect(_string(input, 'proposal_id'));
        return {
          ..._result(record),
          'candidate': record.current.candidate,
          'versions':
              record.versions.map((version) => version.toJson()).toList(),
        };
      case 'review_knowledge_type_proposal':
        if (input['decision'] != null && input['decision'] != 'approve') {
          return _result(
            await runtime.typeReview.decide(
              _string(input, 'proposal_id'),
              decision: _string(input, 'decision'),
              expectedRecordRevision: _integer(input, 'record_revision'),
            ),
          );
        }
        return _result(
          await runtime.typeReview.accept(
            _string(input, 'proposal_id'),
            expectedRecordRevision: _integer(input, 'record_revision'),
          ),
        );
      case 'preview_schema_org':
        final preview = SchemaOrgImporter().preview(
          base64Decode(_string(input, 'content_base64')),
          release: _string(input, 'release'),
          source: Uri.parse(_string(input, 'artifact_source')),
          expectedDigest: input['sha256'] as String?,
        );
        return {
          'release': preview.release,
          'sha256': preview.digest,
          'terms': preview.identities,
          'unsupported': preview.unsupported,
        };
      case 'propose_schema_org':
        final preview = SchemaOrgImporter().preview(
          base64Decode(_string(input, 'content_base64')),
          release: _string(input, 'release'),
          source: Uri.parse(_string(input, 'artifact_source')),
          expectedDigest: input['sha256'] as String?,
        );
        return _result(
          await SchemaOrgImporter().propose(
            preview,
            runtime.typeReview,
            unsupportedDispositions: _object(input['unsupported_dispositions'])
                .cast<String, String>(),
          ),
        );
    }
    throw const FormatException('Unsupported knowledge operation');
  }
}

const _text = {'type': 'string', 'minLength': 1};
const _integer = {'type': 'integer', 'minimum': 1};
const _array = {'type': 'array'};
const _object = {'type': 'object'};
Map<String, Object?> _schema(
  Map<String, Object?> properties,
  List<String> required,
) =>
    {
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    };

/// One schema source shared by HTTP validation, MCP discovery, and client
/// adapters.
final Map<String, Map<String, Object?>> knowledgeOperationSchemas = {
  'list_knowledge_types': _schema(
    {
      'namespace': _text,
      'cursor': _text,
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
    },
    [],
  ),
  'get_knowledge_type': _schema({
    'type_id': _text,
    'version': {
      'oneOf': [
        {'type': 'integer'},
        {'type': 'string'},
      ],
    },
  }, [
    'type_id',
  ]),
  'query_knowledge': _schema(
    {
      'types': _array,
      'properties': _array,
      'relations': _array,
      'sort': _object,
      'cursor': _text,
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
      'traversal': _object,
    },
    [],
  ),
  'inspect_source': _schema(
    {'source_id': _text, 'source_revision': _text, 'locator': _object},
    ['source_id', 'source_revision'],
  ),
  'validate_knowledge_candidate':
      _schema({'operations': _array}, ['operations']),
  'propose_knowledge': _schema(
    {'operations': _array, 'idempotency_key': _text, 'metadata': _object},
    ['operations', 'idempotency_key'],
  ),
  'get_knowledge_proposal': _schema({'proposal_id': _text}, ['proposal_id']),
  'amend_knowledge_proposal': _schema({
    'proposal_id': _text,
    'operations': _array,
    'idempotency_key': _text,
    'record_revision': _integer,
    'proposal_revision': _integer,
  }, [
    'proposal_id',
    'operations',
    'idempotency_key',
    'record_revision',
    'proposal_revision',
  ]),
  'review_knowledge_proposal': _schema({
    'proposal_id': _text,
    'record_revision': _integer,
    'decision': {
      'type': 'string',
      'enum': ['approve', 'deny', 'request_changes'],
    },
  }, [
    'proposal_id',
    'record_revision',
  ]),
  'configure_source_scope': _schema({
    'scope_id': _text,
    'capture_adapters': _array,
    'principals': _array,
    'extraction_enabled': {'type': 'boolean'},
    'trigger': {
      'type': 'string',
      'enum': ['session_end', 'completed_turn', 'both'],
    },
  }, [
    'scope_id',
    'capture_adapters',
    'principals',
  ]),
  'ingest_source': _schema({
    'adapter': _text,
    'event_id': _text,
    'scope_id': _text,
    'content_base64': _text,
    'media_type': _text,
    'automatic': {'type': 'boolean'},
    'observed_at': _text,
    'source_id': _text,
    'observation_kind': {
      'type': 'string',
      'enum': ['import', 'completed_turn', 'session_end'],
    },
    'conversation_id': _text,
  }, [
    'adapter',
    'event_id',
    'scope_id',
    'content_base64',
    'media_type',
  ]),
  'extraction_health': _schema({}, []),
  'purge_source_revision': _schema({
    'source_id': _text,
    'source_revision': _text,
  }, [
    'source_id',
    'source_revision',
  ]),
  'reextract_source': _schema({
    'source_id': _text,
    'source_revision': _text,
    'generation': _text,
  }, [
    'source_id',
    'source_revision',
    'generation',
  ]),
  'preview_knowledge_type_upgrade':
      _schema({'definition': _object}, ['definition']),
  'propose_knowledge_types': _schema(
    {'documents': _object, 'idempotency_key': _text},
    ['documents', 'idempotency_key'],
  ),
  'get_knowledge_type_proposal':
      _schema({'proposal_id': _text}, ['proposal_id']),
  'review_knowledge_type_proposal': _schema({
    'proposal_id': _text,
    'record_revision': _integer,
    'decision': {
      'type': 'string',
      'enum': ['approve', 'deny', 'request_changes'],
    },
  }, [
    'proposal_id',
    'record_revision',
  ]),
  'preview_schema_org': _schema({
    'content_base64': _text,
    'release': _text,
    'artifact_source': _text,
    'sha256': _text,
  }, [
    'content_base64',
    'release',
    'artifact_source',
  ]),
  'propose_schema_org': _schema({
    'content_base64': _text,
    'release': _text,
    'artifact_source': _text,
    'sha256': _text,
    'unsupported_dispositions': _object,
  }, [
    'content_base64',
    'release',
    'artifact_source',
    'unsupported_dispositions',
  ]),
};
