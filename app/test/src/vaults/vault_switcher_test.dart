import 'dart:convert';
import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/vaults/vault_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('signed-in app switches vault and creates one through the API', (
    tester,
  ) async {
    final selected = <String>[];
    final requests = <http.Request>[];
    final api = RobotNotesClient(
      config: const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'key',
        actor: 'tester',
        oauthRefreshToken: 'refresh',
      ),
      httpClient: MockClient((req) async {
        requests.add(req);
        if (req.method == 'PATCH') {
          expect(req.url.path, '/vaults/default');
          expect(jsonDecode(req.body), {'name': 'Personal'});
          return http.Response(
            jsonEncode({'id': 'default', 'name': 'Personal'}),
            200,
          );
        }
        if (req.method == 'POST') {
          expect(jsonDecode(req.body), {'name': 'Projects'});
          return http.Response(
            jsonEncode({'id': 'projects', 'name': 'Projects'}),
            201,
          );
        }
        return http.Response(
          jsonEncode({
            'can_manage': true,
            'vaults': [
              {'id': 'default', 'name': 'Default'},
              {'id': 'work', 'name': 'Work'},
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultSwitcher(
            api: api,
            selectedId: 'default',
            onSelect: selected.add,
            canManage: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();
    expect(selected, ['work']);
    await tester.tap(find.byTooltip('Rename vault'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Personal');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(requests.any((r) => r.method == 'PATCH'), isTrue);
    await tester.tap(find.byTooltip('Create vault'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Projects');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(selected, ['work', 'projects']);
    expect(requests.last.headers['X-Vault-Id'], 'default');
  });

  testWidgets('restricted sessions do not show vault management actions', (
    tester,
  ) async {
    final api = RobotNotesClient(
      config: const AppConfig(
        baseUrl: 'https://notes.example',
        apiKey: 'token',
        actor: 'tester',
        oauthRefreshToken: 'refresh',
      ),
      httpClient: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'can_manage': false,
            'vaults': [
              {'id': 'default', 'name': 'Default'},
            ],
          }),
          200,
        ),
      ),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultSwitcher(
            api: api,
            selectedId: 'default',
            onSelect: (_) {},
            canManage: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Create vault'), findsNothing);
    expect(find.byTooltip('Rename vault'), findsNothing);
  });

  test('selected vault survives normalization and serialization', () {
    const config = AppConfig(
      baseUrl: 'https://notes.example/',
      apiKey: 'key',
      actor: 'tester',
    );
    final selected = config.withVault('work');
    expect(AppConfig.fromJson(selected.normalized().toJson()).vaultId, 'work');
    expect(selected, isNot(config));
  });
}
