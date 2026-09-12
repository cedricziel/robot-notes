import 'package:test/test.dart';

import '../../tool/setup_git_hooks.dart';

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
}
