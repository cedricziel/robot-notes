import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/vault_registry.dart';

/// Lists, creates, or renames vaults according to the authenticated grant.
Future<Response> onRequest(RequestContext context, String id) async {
  final principal = context.read<RestPrincipal>();
  final vaults = context.read<VaultRegistry>();
  if (!principal.canAccessVault(id)) {
    return Response.json(
      statusCode: 403,
      body: {'error': 'vault_access_denied'},
    );
  }
  if (!vaults.contains(id)) {
    return Response.json(statusCode: 404, body: {'error': 'vault_not_found'});
  }
  if (context.request.method == HttpMethod.get) {
    return Response.json(body: vaults.list().firstWhere((v) => v['id'] == id));
  }
  if (context.request.method != HttpMethod.patch) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'method_not_allowed'},
    );
  }
  if (!principal.canManageVaults) {
    return Response.json(
      statusCode: 403,
      body: {'error': 'vault_management_denied'},
    );
  }
  try {
    final body = await context.request.json();
    if (body is! Map<String, dynamic>) {
      return Response.json(statusCode: 400, body: {'error': 'invalid_body'});
    }
    final name = body['name'];
    if (name is! String || name.trim().isEmpty || name.length > 200) {
      throw const FormatException();
    }
    await vaults.rename(id, name.trim());
    return Response.json(body: {'id': id, 'name': name.trim()});
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'invalid_name'});
  }
}
