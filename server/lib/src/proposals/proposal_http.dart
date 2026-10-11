import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/actor.dart';
import 'package:server/src/knowledge_identity.dart';
import 'package:server/src/knowledge_policy.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/proposals/block_compiler.dart';
import 'package:server/src/proposals/proposal_record.dart';
import 'package:server/src/proposals/proposal_service.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/storage.dart';

/// Proposal and comment route shapes share typed errors and trusted identity.
enum ProposalRoute {
  /// Vault review index and new-note draft submission.
  vaultIndex,

  /// Existing-note proposal listing and submission.
  note,

  /// Explicit inspection and CAS amendment.
  item,

  /// Immutable proposal comment append.
  comments,

  /// Authorized final decision.
  decisions,

  /// Standalone accepted-block threads.
  acceptedComments,
}

/// Dispatches REST requests using only trusted credential authority.
Future<Response> proposalRequest(
  RequestContext context,
  ProposalRoute route, {
  String? id,
  String? proposalId,
}) async {
  final method = context.request.method;
  final allowed = switch (route) {
    ProposalRoute.vaultIndex ||
    ProposalRoute.note ||
    ProposalRoute.acceptedComments =>
      const {HttpMethod.get, HttpMethod.post},
    ProposalRoute.item => const {HttpMethod.get, HttpMethod.put},
    ProposalRoute.comments || ProposalRoute.decisions => const {
        HttpMethod.post,
      },
  };
  if (!allowed.contains(method)) {
    return Response.json(
      statusCode: HttpStatus.methodNotAllowed,
      body: const {'error': 'method_not_allowed'},
    );
  }
  try {
    final service = context.read<ProposalService>();
    final actor = context.read<Actor>().name;
    final identity = context.read<RestPrincipal>().knowledgePrincipal;
    final principal =
        context.request.headers['x-robot-notes-agent']?.trim().toLowerCase() ==
                'true'
            ? identity.withAgentOrigin()
            : identity;
    return await withKnowledgePrincipal(principal, () async {
      Map<String, dynamic>? input;
      if (method != HttpMethod.get) {
        final raw = await context.request.json();
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Expected JSON object');
        }
        input = raw;
      }
      switch (route) {
        case ProposalRoute.vaultIndex:
        case ProposalRoute.note:
          if (method == HttpMethod.get) {
            return Response.json(
              body: {
                'items': await service.list(
                  noteId: id,
                  state: context.request.uri.queryParameters['state'],
                  includeTerminal:
                      context.request.uri.queryParameters['include_terminal'] ==
                          'true',
                ),
              },
            );
          }
          final record = id == null
              ? await service.submitNew(input!, actor: actor)
              : await service.submit(id, input!, actor: actor);
          return Response.json(
            statusCode: HttpStatus.created,
            body: {...record.summary(), 'accepted': record.state == 'accepted'},
          );
        case ProposalRoute.item:
          if (method == HttpMethod.put) {
            await service.amend(id!, proposalId!, input!, actor: actor);
          }
          return Response.json(body: await service.inspect(id!, proposalId!));
        case ProposalRoute.comments:
          await service.comment(id!, proposalId!, input!, actor: actor);
          return Response.json(body: await service.inspect(id, proposalId));
        case ProposalRoute.decisions:
          await service.decide(id!, proposalId!, input!, actor: actor);
          return Response.json(body: await service.inspect(id, proposalId));
        case ProposalRoute.acceptedComments:
          return Response.json(
            body: method == HttpMethod.get
                ? await service.acceptedComments(id!)
                : await service.commentAccepted(id!, input!, actor: actor),
          );
      }
    });
  } on KnowledgeAccessDeniedException {
    return Response.json(statusCode: 403, body: {'error': 'forbidden'});
  } on ProposalRecordConflictException catch (error) {
    return Response.json(statusCode: 409, body: {'error': error.reason});
  } on ProposalBlockConflictException catch (error) {
    return Response.json(
      statusCode: 409,
      body: {
        'error': error.reason,
        if (error.blockId != null) 'block_id': error.blockId,
      },
    );
  } on ProposalEvidenceException catch (error) {
    return Response.json(statusCode: 409, body: {'error': error.reason});
  } on BlockMapUnavailableException catch (error) {
    return Response.json(
      statusCode: 409,
      body: {
        'error': error.stale ? 'block_map_stale' : 'block_map_unavailable',
      },
    );
  } on NoteNotFoundException {
    return Response.json(statusCode: 404, body: {'error': 'not_found'});
  } on InvalidPathException {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  } on PathConflictException {
    return Response.json(statusCode: 409, body: {'error': 'path_conflict'});
  } on VersionConflictException {
    return Response.json(
      statusCode: 409,
      body: {'error': 'accepted_base_changed'},
    );
  } on PropertyValidationException {
    return Response.json(
      statusCode: 422,
      body: {'error': 'invalid_properties'},
    );
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  }
}
