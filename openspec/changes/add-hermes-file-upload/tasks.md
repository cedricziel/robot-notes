## 1. Configuration

- [ ] 1.1 Write failing tests: `upload_roots` defaults to empty, loads a list of absolute paths, rejects relative or non-string entries, and round-trips through `save()` only when non-empty.
- [ ] 1.2 Implement `upload_roots` in `RobotNotesConfig`; run tests green; commit `feat(hermes): add upload_roots configuration`.

## 2. Path confinement

- [ ] 2.1 Write failing tests for `resolve_upload_source`: file under root accepted; `..` escape, symlink escape, relative path, missing file, directory rejected; host denylist honored.
- [ ] 2.2 Implement `robot_notes/uploads.py` and the `_hermes_compat` read-block shim; run tests green; commit `feat(hermes): confine upload sources to configured roots`.

## 3. Client

- [ ] 3.1 Write failing respx tests: `upload_file` posts multipart `path` + `file` to `/notes/files` with auth headers, returns the 201 body, and maps 409/413/422 to `ClientError` codes.
- [ ] 3.2 Implement `RobotNotesClient.upload_file`; run tests green; commit `feat(hermes): add multipart file upload to the REST client`.

## 4. Tool

- [ ] 4.1 Write failing provider tests: schema hidden without roots and disabled call errors; schema and prompt line present with roots; success returns only metadata; path denial makes no request; read-only context refuses; server `path_conflict` surfaces.
- [ ] 4.2 Implement the schema, handler, write gating, and prompt line; run tests green; commit `feat(hermes): add robotnotes_upload_file tool`.

## 5. Docs and verification

- [ ] 5.1 Update plugin `README.md` (configuration, tool) and `TOOL_INVENTORY.md`.
- [ ] 5.2 Add an e2e test uploading a file to a real server and run `make test-hermes-plugin-e2e`.
- [ ] 5.3 Run `make test-hermes-plugin`, the contract suite, lint, and `openspec validate --strict`; run `/simplify`.

## Definition of Done

All scenarios in `specs/hermes-file-upload/spec.md` have passing tests, the e2e upload passes against a real server, existing plugin tests pass unchanged, installs without `upload_roots` see no new tool or prompt text, and each step is an atomic conventional commit. Each task is at most 15 minutes; failing tests come first.
