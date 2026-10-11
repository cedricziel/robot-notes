import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/agent_credentials.dart';
import 'package:server/src/rest_principal.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.read<RestPrincipal>().kind != RestAuthKind.staticKey) {
    return Response.json(statusCode: 403, body: {'error': 'operator_required'});
  }
  if (context.request.method != HttpMethod.delete) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'method_not_allowed'},
    );
  }
  if (!await context.read<AgentCredentialStore>().revoke(id)) {
    return Response.json(
      statusCode: 404,
      body: {'error': 'credential_not_found'},
    );
  }
  return Response(statusCode: 204);
}
