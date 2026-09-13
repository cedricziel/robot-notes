import 'dart:convert';
import 'dart:typed_data';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/files/picked_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

void main() {
  group('uploadPickedFile', () {
    test('returns null without making a request when the picker is '
        'cancelled', () async {
      var requested = false;
      final api = RobotNotesClient(
        config: _config,
        httpClient: MockClient((request) async {
          requested = true;
          return http.Response('', 500);
        }),
      );
      addTearDown(api.close);

      final result = await uploadPickedFile(api, () async => null);

      expect(result, isNull);
      expect(requested, isFalse);
    });

    test(
      'POSTs the picked file to /notes/files and returns the result',
      () async {
        String? capturedPath;
        String? capturedMethod;
        final mock = MockClient.streaming((request, bodyStream) async {
          capturedPath = request.url.path;
          capturedMethod = request.method;
          final multipart = request as http.MultipartRequest;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'path': multipart.fields['path'],
                  'filename': multipart.files.single.filename,
                  'size': 3,
                  'content_type': 'application/octet-stream',
                }),
              ),
            ),
            201,
            request: request,
          );
        });
        final api = RobotNotesClient(config: _config, httpClient: mock);

        final result = await uploadPickedFile(
          api,
          () async => PickedFile(name: 'diagram.png', bytes: Uint8List(3)),
          path: 'Projects/Alpha',
        );

        expect(capturedMethod, 'POST');
        expect(capturedPath, '/notes/files');
        expect(result?.path, 'Projects/Alpha');
        expect(result?.filename, 'diagram.png');
      },
    );
  });
}
