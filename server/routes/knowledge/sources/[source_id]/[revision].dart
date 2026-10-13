import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/knowledge/adapters.dart';

/// Returns immutable original bytes under the selected source scope.
Future<Response> onRequest(
  RequestContext context,
  String sourceId,
  String revision,
) =>
    knowledgeSourceBytesRequest(context, sourceId, revision);
