import 'dart:io';

const preCommitHookScript = '''#!/bin/sh
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
exec dart run dart_pre_commit
''';

Future<Directory> resolveHooksDir({required Directory repoRoot}) async {
  final result = await Process.run('git', [
    'rev-parse',
    '--git-path',
    'hooks',
  ], workingDirectory: repoRoot.path);

  if (result.exitCode != 0) {
    throw StateError('git rev-parse --git-path hooks failed: ${result.stderr}');
  }

  final gitPath = (result.stdout as String).trim();
  // --git-path prints a path relative to repoRoot when core.hooksPath is a
  // relative path (worktree-specific); it prints an absolute path for the
  // shared main-checkout hooks dir and for an absolute core.hooksPath.
  final resolvedPath = gitPath.startsWith('/')
      ? gitPath
      : '${repoRoot.path}/$gitPath';

  return Directory(resolvedPath);
}

Future<void> main() async {
  final hooksDir = await resolveHooksDir(repoRoot: Directory.current);
  await hooksDir.create(recursive: true);

  final hookFile = File('${hooksDir.path}/pre-commit');
  await hookFile.writeAsString(preCommitHookScript);

  if (!Platform.isWindows) {
    final result = await Process.run('chmod', ['a+x', hookFile.path]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    exitCode = result.exitCode;
  }

  stdout.writeln('Installed pre-commit hook at ${hookFile.path}');
}
