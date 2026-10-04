import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/databases/registry.dart';
import 'package:server/src/link_index.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/note_write_service.dart';
import 'package:server/src/rest_principal.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/upload_sessions.dart';
import 'package:server/src/vault_files.dart';
import 'package:server/src/vault_registry.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';

/// Selects an isolated vault before any content handler executes.
Middleware vaultSelection(VaultRegistry vaults) =>
    (handler) => (context) async {
          final path = context.request.uri.path;
          if (!(path == '/notes' ||
              path.startsWith('/notes/') ||
              path == '/search' ||
              path == '/tags' ||
              path == '/ws' ||
              path == '/databases' ||
              path.startsWith('/databases/'))) {
            return handler(context);
          }
          final id = context.request.headers['x-vault-id'] ??
              context.request.uri.queryParameters['vault_id'] ??
              'default';
          final principal = context.read<RestPrincipal>();
          if (principal.kind == RestAuthKind.oauthToken &&
              !principal.canAccessVault(id)) {
            return Response.json(
              statusCode: 403,
              body: {'error': 'vault_access_denied'},
            );
          }
          if (!vaults.contains(id)) {
            return Response.json(
              statusCode: 404,
              body: {'error': 'vault_not_found'},
            );
          }
          final deps = await vaults.open(id);
          return handler(
            context
                .provide<Storage>(() => deps.storage)
                .provide<MetaIndex>(() => deps.metaIndex)
                .provide<SearchIndex>(() => deps.searchIndex)
                .provide<LinkIndex>(() => deps.linkIndex)
                .provide<LockManager>(() => deps.lockManager)
                .provide<NoteWriteService>(() => deps.noteWriteService)
                .provide<DatabaseRegistry>(() => deps.registry)
                .provide<FileStore>(() => deps.fileStore)
                .provide<UploadSessionStore>(() => deps.uploadSessions)
                .provide<Broadcaster>(() => deps.broadcaster)
                .provide<PresenceTracker>(() => deps.presence),
          );
        };
