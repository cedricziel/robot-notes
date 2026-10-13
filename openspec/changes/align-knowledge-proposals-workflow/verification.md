## Verification

- All 20 tests in `app/test/src/knowledge` passed, including direct existing-note review, draft retention across resizing and failed decisions, inline comment persistence, conflict revision refresh, unavailable accepted targets, permissions, and duplicate-submission protection.
- Flutter analysis of the knowledge implementation and tests reported no issues. Dart formatting, `git diff --check`, and strict OpenSpec validation passed.
- The final Flutter web build passed.
- A disposable loopback server with isolated HTTP and VM-service ports, data, and credentials served the real app. The UI posted a comment and approved new knowledge. API reads confirmed the persisted comment, accepted proposal, and accepted note content.
- The app displayed an existing-note replacement directly with verified accepted text, proposed text, and supporting evidence. The accepted filter retained access to completed reviews.
- Browser layout checks covered 390×844, 844×390, 768×1024, 1024×768, and 1440×900. A widget test checked Apple dark theme with 1.8× text scaling. These checks do not establish native device runtime coverage.
- The verification tab closed, the viewport override reset, and the disposable server stopped. Temporary data and credentials were removed.

## Repository checks

The commit hook initially reported unresolved imports in the existing editor-compatibility harnesses. Resolving each harness with `flutter pub get --enforce-lockfile` restored analysis without changing its lockfile.
