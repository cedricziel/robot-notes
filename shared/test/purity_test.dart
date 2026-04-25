import 'dart:io';

import 'package:test/test.dart';

/// Guards the `shared` package's reason for existing: it ships to the Flutter
/// app, so it must NOT pull in Flutter, the server framework, or anything
/// that smells like server-only platform code.
void main() {
  test('no source file imports a banned package or dart:io', () {
    final forbiddenPrefixes = <String>[
      'package:flutter/',
      'package:flutter_test',
      'package:dart_frog',
      'package:shelf/',
      'package:sqlite3/',
      'package:sqlite3_flutter_libs',
      'package:yaml/',
      'package:ulid/',
      'dart:io',
      'dart:ffi',
      'dart:isolate',
      'dart:mirrors',
      'dart:html',
    ];

    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'shared/lib should exist');

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    expect(dartFiles, isNotEmpty, reason: 'shared/lib should hold Dart files');

    final violations = <String>[];
    final importRe =
        RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''', multiLine: true);

    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      for (final m in importRe.allMatches(source)) {
        final uri = m.group(1)!;
        for (final bad in forbiddenPrefixes) {
          if (uri == bad || uri.startsWith(bad)) {
            violations.add('${file.path}: import "$uri"');
            break;
          }
        }
      }
    }

    expect(violations, isEmpty,
        reason:
            'shared/ must stay pure. Found banned imports:\n${violations.join('\n')}');
  });
}
