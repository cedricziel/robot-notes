import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/vault_registry.dart';

/// Lists, creates, or renames vaults according to the authenticated grant.
Future<Response> onRequest(RequestContext context) async {
  final vaults = context.read<VaultRegistry>();
  final principal = context.read<RestPrincipal>();
  if (context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        'can_manage': principal.canManageVaults,
        'vaults': [
          for (final vault in vaults.list())
            if (principal.canAccessVault(vault['id']!)) vault,
        ],
      },
    );
  }
  if (context.request.method != HttpMethod.post) {
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
    return Response.json(
      statusCode: 201,
      body: await vaults.create(name.trim()),
    );
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'invalid_name'});
  }
}
