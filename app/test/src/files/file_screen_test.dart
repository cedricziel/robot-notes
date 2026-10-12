import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/files/file_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'secret-key',
  actor: 'test-user',
  vaultId: 'selected-vault',
);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

http.Response _listing({
  String filename = 'diagram.png',
  String contentType = 'image/png',
  int size = 68,
}) => http.Response(
  jsonEncode({
    'items': [
      {
        'path': 'Projects',
        'filename': filename,
        'size': size,
        'content_type': contentType,
        'updated_at': '2026-10-12T10:00:00Z',
      },
    ],
  }),
  200,
);

Future<void> _open(
  WidgetTester tester,
  RobotNotesClient api, {
  String path = 'Projects/diagram.png',
  VoidCallback? onClose,
  SaveFile? saveFile,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: FileScreen(
        api: api,
        relativePath: path,
        onClose: onClose ?? () {},
        saveFile:
            saveFile ??
            ({required filename, required bytes, required contentType}) async =>
                null,
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('changing files ignores metadata from the earlier destination', (
    tester,
  ) async {
    final earlierListing = Completer<http.Response>();
    var first = true;
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        expect(request.url.path, '/notes/files');
        if (first) {
          first = false;
          return earlierListing.future;
        }
        return _listing(filename: 'report.pdf', contentType: 'application/pdf');
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: FileScreen(
          api: api,
          relativePath: 'Projects/diagram.png',
          onClose: () {},
        ),
      ),
    );
    await tester.pump();

    await _open(tester, api, path: 'Projects/report.pdf');
    earlierListing.complete(_listing());
    await tester.pumpAndSettle();

    expect(find.text('Projects/report.pdf'), findsOneWidget);
    expect(find.text('application/pdf'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('rejects a preview larger than its advertised metadata', (
    tester,
  ) async {
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/files') return _listing();
        return http.Response.bytes(Uint8List(10 * 1024 * 1024 + 1), 200);
      }),
    );
    addTearDown(api.close);

    await _open(tester, api);

    expect(find.byType(Image), findsNothing);
    expect(
      find.text('Image exceeds the 10 MiB preview limit.'),
      findsOneWidget,
    );
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('failed download keeps details and allows another attempt', (
    tester,
  ) async {
    var unavailable = true;
    Uint8List? saved;
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/files') {
          return _listing(
            filename: 'report.pdf',
            contentType: 'application/pdf',
          );
        }
        return unavailable
            ? http.Response('', 503)
            : http.Response.bytes([4, 5], 200);
      }),
    );
    addTearDown(api.close);
    await _open(
      tester,
      api,
      path: 'Projects/report.pdf',
      saveFile:
          ({required filename, required bytes, required contentType}) async {
            saved = bytes;
            return Uri.file('/saved/report.pdf');
          },
    );
    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Could not download file. Try again.'), findsOneWidget);
    expect(find.text('application/pdf'), findsOneWidget);

    unavailable = false;
    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(saved, [4, 5]);
    expect(find.text('Could not download file. Try again.'), findsNothing);
  });

  testWidgets('previews an image fetched with vault authentication', (
    tester,
  ) async {
    http.Request? byteRequest;
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        if (request.url.path == '/notes/files') {
          expect(request.url.queryParameters['path'], 'Projects');
          return _listing();
        }
        byteRequest = request;
        return http.Response.bytes(_png, 200);
      }),
    );
    addTearDown(api.close);

    await _open(tester, api);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('image/png'), findsOneWidget);
    expect(byteRequest?.headers['Authorization'], 'Bearer secret-key');
    expect(byteRequest?.headers['X-Vault-Id'], 'selected-vault');
    expect(byteRequest?.url.path, '/notes/files/Projects/diagram.png');
    expect(byteRequest?.url.query, isEmpty);
  });

  testWidgets('non-images show metadata without fetching content', (
    tester,
  ) async {
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        expect(request.url.path, '/notes/files');
        return _listing(
          filename: 'report.pdf',
          contentType: 'application/pdf',
          size: 1234,
        );
      }),
    );
    addTearDown(api.close);

    await _open(tester, api, path: 'Projects/report.pdf');

    expect(find.text('application/pdf'), findsOneWidget);
    expect(find.text('1234 bytes'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('oversized images show details without fetching content', (
    tester,
  ) async {
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((request) async {
        expect(request.url.path, '/notes/files');
        return _listing(size: 10 * 1024 * 1024 + 1);
      }),
    );
    addTearDown(api.close);

    await _open(tester, api);

    expect(find.byType(Image), findsNothing);
    expect(
      find.text('Image exceeds the 10 MiB preview limit.'),
      findsOneWidget,
    );
    expect(find.text('10485761 bytes'), findsOneWidget);
  });

  testWidgets('missing files offer retry and return', (tester) async {
    var returned = false;
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient((_) async => http.Response('{"items":[]}', 200)),
    );
    addTearDown(api.close);

    await _open(tester, api, onClose: () => returned = true);

    expect(find.text('File not found.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Return'));
    expect(returned, isTrue);
  });

  testWidgets('retry recovers from a failed metadata request', (tester) async {
    var unavailable = true;
    final api = RobotNotesClient(
      config: _config,
      httpClient: MockClient(
        (_) async => unavailable
            ? http.Response('', 503)
            : _listing(filename: 'report.pdf', contentType: 'application/pdf'),
      ),
    );
    addTearDown(api.close);
    await _open(tester, api, path: 'Projects/report.pdf');

    unavailable = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('application/pdf'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'download saves authenticated bytes with original filename and type',
    (tester) async {
      Uint8List? savedBytes;
      String? savedFilename;
      String? savedType;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          if (request.url.path == '/notes/files') {
            return _listing(
              filename: 'report.pdf',
              contentType: 'application/pdf',
            );
          }
          expect(request.headers['Authorization'], 'Bearer secret-key');
          expect(request.headers['X-Actor'], 'test-user');
          expect(request.headers['X-Vault-Id'], 'selected-vault');
          expect(request.url.path, '/notes/files/Projects/report.pdf');
          expect(request.url.query, isEmpty);
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      addTearDown(api.close);
      await _open(
        tester,
        api,
        path: 'Projects/report.pdf',
        saveFile:
            ({required filename, required bytes, required contentType}) async {
              savedBytes = bytes;
              savedFilename = filename;
              savedType = contentType;
              return Uri.file('/saved/report.pdf');
            },
      );

      await tester.tap(find.text('Download'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(savedBytes, [1, 2, 3]);
      expect(savedFilename, 'report.pdf');
      expect(savedType, 'application/pdf');
    },
  );
}
