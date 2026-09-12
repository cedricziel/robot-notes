import 'dart:io';

const preCommitHookScript = '''#!/bin/sh
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
exec dart run dart_pre_commit
''';

Future<void> main() async {
  final hookFile = File('.git/hooks/pre-commit');
  await hookFile.parent.create(recursive: true);
  await hookFile.writeAsString(preCommitHookScript);

  if (!Platform.isWindows) {
    final result = await Process.run('chmod', ['a+x', hookFile.path]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    exitCode = result.exitCode;
  }

  stdout.writeln('Installed pre-commit hook at ${hookFile.path}');
}
