import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/proposals/proposal_http.dart';

/// Dispatches versioned proposal review and block comment activity.
Future<Response> onRequest(
  RequestContext context,
  String id,
  String proposalId,
) =>
    proposalRequest(
      context,
      ProposalRoute.comments,
      id: id,
      proposalId: proposalId,
    );
