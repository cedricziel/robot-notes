import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge/adapters.dart';

/// Dispatches the shared selected-vault knowledge operation contract.
Future<Response> onRequest(RequestContext context, String operation) =>
    knowledgeOperationRequest(context, operation);
