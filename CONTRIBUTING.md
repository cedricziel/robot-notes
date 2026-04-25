# Contributing to robot-notes

## After cloning

```sh
dart pub get
dart run tool/setup_git_hooks.dart
```

The second command installs a `pre-commit` hook into `.git/hooks/` that runs
[`dart_pre_commit`](https://pub.dev/packages/dart_pre_commit) before each
commit (formatting + analysis). The hook is per-clone — every contributor
runs the install once.

## Pre-commit checks

The hook runs `dart format` and `dart analyze` against staged Dart files.
Configuration lives in the root `pubspec.yaml` under the `dart_pre_commit:`
key. Additional checks (`outdated`, `flutter-compat`, etc.) can be enabled
there as the project grows.

## Commit messages

Commits SHALL follow [conventional-commits](https://www.conventionalcommits.org/).
Allowed types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`,
`build`, `perf`. Mark breaking changes with `!` after the type or a
`BREAKING CHANGE:` footer.

A separate commit-message linter (commitlint via the CI workflow) is added
in the implementation phase — see task 26 of the `add-mvp-foundation`
OpenSpec change.
