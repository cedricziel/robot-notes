import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/databases/databases_controller.dart';
import 'package:app/src/notes/folder_tree_controller.dart';
import 'package:app/src/notes/notes_list_controller.dart';
import 'package:app/src/notes/note_screen.dart';
import 'package:app/src/realtime/connection_status.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'tester',
);
Map<String, Object?> _note(
  String id, {
  String content = 'Original',
  int version = 1,
}) => {
  'id': id,
  'title': id,
  'content': content,
  'version': version,
  'created_at': '2025-01-01T00:00:00Z',
  'updated_at': '2025-01-01T00:00:00Z',
};
void main() {
  for (final scenario in [
    'failure',
    'success',
    'resize',
    'folder',
    'file',
    'vault',
  ]) {
    final succeeds = scenario == 'success';
    final resize = scenario == 'resize';
    testWidgets(
      resize
          ? 'responsive resizing retains unsaved draft and acquired controller'
          : succeeds
          ? 'same-route replacement saves before releasing the lock'
          : 'same-route replacement retains the draft when saving fails',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final operations = <String>[];
        final api = RobotNotesClient(
          config: _config,
          httpClient: MockClient((request) async {
            final path = request.url.path;
            operations.add('${request.method} $path');
            if (path.endsWith('/lock')) {
              return http.Response(
                jsonEncode({
                  'holder': 'tester',
                  'expires_at': '2099-01-01T00:00:00Z',
                }),
                200,
              );
            }
            if (request.method == 'PUT' && path == '/notes/01A') {
              return succeeds
                  ? http.Response(
                      jsonEncode(_note('01A', content: 'Draft', version: 2)),
                      200,
                    )
                  : http.Response('unavailable', 500);
            }
            if (path == '/notes/01A' || path == '/notes/01B') {
              return http.Response(
                jsonEncode(_note(path.split('/').last)),
                200,
              );
            }
            if (path == '/notes/tree') {
              return http.Response(jsonEncode({'folders': <Object?>[]}), 200);
            }
            return http.Response(
              jsonEncode({
                'items': <Object?>[],
                'limit': 50,
                'next_cursor': null,
              }),
              200,
            );
          }),
        );
        final ws = RobotNotesWsClient(config: _config);
        final list = NotesListController(api: api);
        final tree = FolderTreeController(api: api);
        final databases = DatabasesController(api: api);
        final connection = ValueNotifier(ConnectionStatus.connected);
        final holder = ConfigHolder.seeded(_config);
        addTearDown(holder.dispose);
        final router = buildAppRouter(
          configHolder: holder,
          initialLocation: '/notes/01A',
        );
        addTearDown(() async {
          router.dispose();
          list.dispose();
          tree.dispose();
          databases.dispose();
          connection.dispose();
          await ws.dispose();
          api.close();
        });
        await tester.pumpWidget(
          MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => AppSession(
              api: api,
              ws: ws,
              list: list,
              tree: tree,
              databases: databases,
              actor: _config.actor,
              baseUrl: _config.baseUrl,
              connection: connection,
              onReset: () {},
              child: child!,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('note.menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('note.source')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('note.editor.content')),
          'Draft',
        );
        final controller = tester
            .widget<NoteScreen>(find.byType(NoteScreen))
            .controller;
        operations.clear();
        if (resize) {
          for (final width in [839.0, 840.0, 839.0, 840.0, 1400.0]) {
            tester.view.physicalSize = Size(width, 900);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 150));
            expect(
              tester.widget<NoteScreen>(find.byType(NoteScreen)).controller,
              same(controller),
            );
            expect(controller.value.editContent, 'Draft');
            expect(controller.value.isDirty, isTrue);
            final field = tester.widget<TextField>(
              find.byKey(const Key('note.editor.content')),
            );
            expect(field.controller!.text, 'Draft');
          }
          expect(operations, isNot(contains('PUT /notes/01A')));
          expect(operations, isNot(contains('POST /notes/01A/lock')));
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(days: 36500));
          await tester.pumpAndSettle();
          return;
        }
        if (scenario == 'vault') {
          final changing = holder.selectVault('work');
          await tester.pumpAndSettle();
          expect(await changing, isFalse);
          expect(holder.config!.vaultId, 'default');
        } else {
          router.go(
            scenario == 'folder'
                ? '/?folder=Projects'
                : scenario == 'file'
                ? '/file?path=test.pdf'
                : '/notes/01B',
          );
        }
        await tester.pumpAndSettle();
        expect(
          router.routeInformationProvider.value.uri.path,
          succeeds ? '/notes/01B' : '/notes/01A',
        );
        expect(operations, contains('PUT /notes/01A'));
        if (succeeds) {
          expect(
            operations.indexOf('PUT /notes/01A'),
            lessThan(operations.indexOf('DELETE /notes/01A/lock')),
          );
          expect(operations, contains('GET /notes/01B'));
        } else {
          expect(operations, isNot(contains('DELETE /notes/01A/lock')));
          final field = tester.widget<TextField>(
            find.byKey(const Key('note.editor.content')),
          );
          expect(field.controller!.text, 'Draft');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(days: 36500));
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant(
        resize
            ? {TargetPlatform.macOS, TargetPlatform.iOS, TargetPlatform.android}
            : {TargetPlatform.linux},
      ),
    );
  }
}
