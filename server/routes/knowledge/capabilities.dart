import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge/adapters.dart';

/// Reports availability without granting content or mutation permissions.
Future<Response> onRequest(RequestContext context) =>
    knowledgeOperationRequest(context, 'capabilities');
