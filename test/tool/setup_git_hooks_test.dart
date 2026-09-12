import 'dart:io';

import 'package:test/test.dart';

import '../../tool/setup_git_hooks.dart';

Future<void> _git(List<String> args, {required String workingDirectory}) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

void main() {
  test('unsets the git-exported env vars before running dart_pre_commit', () {
    expect(
      preCommitHookScript,
      contains('unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE'),
    );
  });

  test('unsets the env vars before invoking dart_pre_commit, not after', () {
    final unsetIndex = preCommitHookScript.indexOf('unset GIT_DIR');
    final execIndex = preCommitHookScript.indexOf('dart run dart_pre_commit');
    expect(unsetIndex, greaterThanOrEqualTo(0));
    expect(unsetIndex, lessThan(execIndex));
  });

  test('still runs dart_pre_commit', () {
    expect(preCommitHookScript, contains('dart run dart_pre_commit'));
  });

  test('is a POSIX sh script', () {
    expect(preCommitHookScript, startsWith('#!/bin/sh\n'));
  });

  group('resolveHooksDir', () {
    late Directory tempRoot;
    late Directory mainRepo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('setup_git_hooks_test_');
      mainRepo = Directory('${tempRoot.path}/main-repo');
      await mainRepo.create(recursive: true);
      await _git(['init', '-q'], workingDirectory: mainRepo.path);
      await _git([
        'config',
        'user.email',
        'test@example.com',
      ], workingDirectory: mainRepo.path);
      await _git([
        'config',
        'user.name',
        'Test',
      ], workingDirectory: mainRepo.path);
      await _git([
        'commit',
        '--allow-empty',
        '-q',
        '-m',
        'init',
      ], workingDirectory: mainRepo.path);
    });

    tearDown(() async {
      await tempRoot.delete(recursive: true);
    });

    test('resolves to <repo>/.git/hooks for a plain checkout', () async {
      final hooksDir = await resolveHooksDir(repoRoot: mainRepo);

      expect(
        hooksDir.resolveSymbolicLinksSync(),
        Directory('${mainRepo.path}/.git/hooks').resolveSymbolicLinksSync(),
      );
    });

    test(
      'resolves a worktree to the main checkout\'s shared hooks dir',
      () async {
        final worktree = Directory('${tempRoot.path}/worktree');
        await _git([
          'worktree',
          'add',
          '-q',
          worktree.path,
          '-b',
          'wt-branch',
        ], workingDirectory: mainRepo.path);

        final hooksDir = await resolveHooksDir(repoRoot: worktree);

        expect(
          hooksDir.resolveSymbolicLinksSync(),
          Directory('${mainRepo.path}/.git/hooks').resolveSymbolicLinksSync(),
        );
      },
    );
  });
}
