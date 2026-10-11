import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/agent_credentials.dart';
import 'package:server/src/oauth/metadata.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/vault_registry.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.read<RestPrincipal>().kind != RestAuthKind.staticKey) {
    return Response.json(statusCode: 403, body: {'error': 'operator_required'});
  }
  final store = context.read<AgentCredentialStore>();
  if (context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        'items': [for (final r in await store.list()) r.summary()],
      },
    );
  }
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'method_not_allowed'},
    );
  }
  dynamic body;
  try {
    body = await context.request.json();
  } on FormatException {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  }
  if (body is! Map<String, dynamic> ||
      body['actor'] is! String ||
      (body['actor'] as String).trim().isEmpty) {
    return Response.json(statusCode: 400, body: {'error': 'bad_request'});
  }
  final scopes = _strings(body['scopes']) ??
      (body.containsKey('scopes') ? null : kDefaultAgentScopes);
  final vaultIds = _strings(body['vault_ids']) ??
      (body.containsKey('vault_ids') ? null : const {'default'});
  if (scopes == null ||
      scopes.isEmpty ||
      !scopes.every(kOAuthScopes.contains) ||
      vaultIds == null ||
      vaultIds.isEmpty ||
      !vaultIds.every(context.read<VaultRegistry>().contains)) {
    return Response.json(statusCode: 400, body: {'error': 'invalid_grant'});
  }
  final issued = await store.issue(
    actor: body['actor'] as String,
    scopes: scopes,
    vaultIds: vaultIds,
  );
  return Response.json(
    statusCode: 201,
    headers: {'Cache-Control': 'no-store'},
    body: {...issued.record.summary(), 'secret': issued.secret},
  );
}

Set<String>? _strings(dynamic value) {
  if (value is! List<dynamic> || !value.every((dynamic v) => v is String)) {
    return null;
  }
  return value.cast<String>().toSet();
}
