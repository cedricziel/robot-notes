# Changelog

## [0.1.1](https://github.com/cedricziel/robot-notes/compare/v0.1.0...v0.1.1) (2026-04-25)


### Features

* **server:** log resolved config on startup; make run-server work out of the box ([32f0210](https://github.com/cedricziel/robot-notes/commit/32f021020208e50e99bd42f316f2139b3f5b82e9))


### Bug Fixes

* **app:** grant outbound network entitlement to macOS app ([34bdd23](https://github.com/cedricziel/robot-notes/commit/34bdd23fe35e531640bb8704ddb8f1e292671c37))
* **app:** send non-empty title from create-note FAB ([8490595](https://github.com/cedricziel/robot-notes/commit/8490595611762127cf31abea86f57f1c227e77e6))
* **ci:** build multi-arch image on native runners ([89700b2](https://github.com/cedricziel/robot-notes/commit/89700b219e04d08d93ff9da781f2d2edd712eef9))
* **ci:** gate publish jobs on resolve-tag output, not implicit success() ([889c0f9](https://github.com/cedricziel/robot-notes/commit/889c0f9b2ea260290171fe0f35561b1a4582ebd6))
* **ci:** use always() so the if-gate actually evaluates after a skipped dep ([dcdb55d](https://github.com/cedricziel/robot-notes/commit/dcdb55d389cab52c27c96bc72003628e09d9ec8d))
* **server:** stop feeding VM args to Config parser ([39b6d9b](https://github.com/cedricziel/robot-notes/commit/39b6d9baed868c8f1a6f5b36fb6b33c3b0411397))

## 0.1.0 (2026-04-25)


### Features

* **app:** add first-run setup flow with secure config storage ([882978f](https://github.com/cedricziel/robot-notes/commit/882978f04dd8d8b9e0d7e1865629bf34812d63cc))
* **app:** add note view with editor lock, heartbeat, and 409/423 reconcile ([6cc3119](https://github.com/cedricziel/robot-notes/commit/6cc31194818e094374e113591b923bce16f69070))
* **app:** add notes list view with live changed-event reconciliation ([2737265](https://github.com/cedricziel/robot-notes/commit/2737265b2f31d17a07abeb4da7a3ced614e2ae02))
* **app:** add reconnecting WebSocket client with stale-view detection ([c6f2142](https://github.com/cedricziel/robot-notes/commit/c6f2142fb570924f15de509c992f2eea63dd015d))
* **app:** add search view with debounced FTS5 query and snippet markup ([f5e3c90](https://github.com/cedricziel/robot-notes/commit/f5e3c90ea2e200523d3df4835cdff6b296b3eb82))
* **app:** add typed RobotNotesClient for the v1 HTTP API ([743ad49](https://github.com/cedricziel/robot-notes/commit/743ad490d2c3667a909512e617d6d07a24d82c05))
* **app:** scaffold Flutter multi-platform client with riverpod, http, ws, secure storage ([4d54622](https://github.com/cedricziel/robot-notes/commit/4d546225c0cf91b72ae9782805d12dc74936bb6b))
* **app:** wire setup, notes, editor, and search into main shell ([fa880e8](https://github.com/cedricziel/robot-notes/commit/fa880e8a88ec7821135bc6d5d0fef1ca6306df9a))
* **release:** expose release version through release-please ([862a367](https://github.com/cedricziel/robot-notes/commit/862a367437f40d95e10caf67db67d45a2436a20f))
* **server:** add /ws Dart Frog route and ChannelWsSink adapter ([04e3b9e](https://github.com/cedricziel/robot-notes/commit/04e3b9ee32f4d834608bf652570bb2b3866f0b8b))
* **server:** add Broadcaster for per-connection WS event fanout ([798b662](https://github.com/cedricziel/robot-notes/commit/798b662729df36137265a3f06d5e6107a579b791))
* **server:** add filesystem-backed InviteStore with atomic burn ([dcf450d](https://github.com/cedricziel/robot-notes/commit/dcf450d9b82682476be1e2793fbd191c9320ad67))
* **server:** add FTS5-backed SearchIndex with rebuild on missing/corrupt/stale ([c9dff60](https://github.com/cedricziel/robot-notes/commit/c9dff60dd598ad5dc7dad365b5959a7dac8177a9))
* **server:** add GET /search route backed by SearchIndex ([8f359e5](https://github.com/cedricziel/robot-notes/commit/8f359e59638862ac040a4dafcf434b55dbff4db9))
* **server:** add hardened multi-stage Dockerfile ([ab80918](https://github.com/cedricziel/robot-notes/commit/ab809188d0df6238ead2a346ca280d013d9af7ea))
* **server:** add invite routes and single-use onboarding bundle ([76bace4](https://github.com/cedricziel/robot-notes/commit/76bace452f3334b0e156e5d123e7bd541cdea285))
* **server:** add NoteWriteService to orchestrate storage+search+meta+broadcast on note writes ([d21df11](https://github.com/cedricziel/robot-notes/commit/d21df11d69d1c17b29571f3dd7dc4f81cca5e95a))
* **server:** add PresenceTracker for per-note WS viewer rosters ([89bfeea](https://github.com/cedricziel/robot-notes/commit/89bfeea754723302f87785a1d8cd349eeb30166f))
* **server:** add WsConnection state machine and slow-consumer eviction ([0ded233](https://github.com/cedricziel/robot-notes/commit/0ded23310af99686ab94114e99bd54bea6367656))
* **server:** bearer-token auth middleware with /healthz bypass ([ba56ee1](https://github.com/cedricziel/robot-notes/commit/ba56ee142cc5caed7de9724e038f7a1dcb2f67dd))
* **server:** bootstrap shared AppDeps and provide them via middleware ([ec16dcb](https://github.com/cedricziel/robot-notes/commit/ec16dcb40c7da222d4ecb7c099d611932314875b))
* **server:** embed flutter web bundle in the docker image and serve it at / ([4d28fab](https://github.com/cedricziel/robot-notes/commit/4d28fab92ce756f6daab2de9bf6489e59ad10de0))
* **server:** file-backed Storage with atomic writes and per-id mutex ([2855f11](https://github.com/cedricziel/robot-notes/commit/2855f113f2c5a67fe03de4bc0cfb0c5bd4712ed3))
* **server:** GET /healthz liveness endpoint ([cf1eb60](https://github.com/cedricziel/robot-notes/commit/cf1eb60b1f4904581d65f854ed87da5076f7e140))
* **server:** GET /notes (list) and POST /notes (create) handlers ([ef5ea10](https://github.com/cedricziel/robot-notes/commit/ef5ea10e282490687656041a58a56cd0691809e3))
* **server:** GET/PUT/DELETE /notes/{id} with optimistic concurrency ([9fc41df](https://github.com/cedricziel/robot-notes/commit/9fc41df36b12402cd595c7eb95b6256023222822))
* **server:** in-memory MetaIndex with cursor pagination ([897ae85](https://github.com/cedricziel/robot-notes/commit/897ae85ab7425989a91062c65ad311489ee78dd4))
* **server:** in-memory soft editor LockManager with transitions stream ([df07acb](https://github.com/cedricziel/robot-notes/commit/df07acb1df62b5cbc861bc8fd1d70b3144bbca57))
* **server:** POST/PUT/DELETE /notes/{id}/lock for soft editor lock ([0f9144e](https://github.com/cedricziel/robot-notes/commit/0f9144e2ad28d4dca48dbc1a2b9294463bcdf829))
* **server:** scaffold the Dart Frog server ([2259b24](https://github.com/cedricziel/robot-notes/commit/2259b244bc308c401a02092845ee1419d4f71601))
* **server:** startup Config from CLI args + ROBOT_NOTES_* env vars ([8835938](https://github.com/cedricziel/robot-notes/commit/88359382dcfed815706ef055d9ad95b046cdb70d))
* **server:** wire broadcaster + presence into AppDeps and notes routes ([443cf37](https://github.com/cedricziel/robot-notes/commit/443cf3743c76a3b00bd7a37715166f6c656f7830))
* **server:** X-Actor identity middleware with unknown fallback ([81ad54f](https://github.com/cedricziel/robot-notes/commit/81ad54f7f7ad01e908686dde3cda479f2a4d5e9a))
* **server:** YAML frontmatter parse and serialize ([35ed993](https://github.com/cedricziel/robot-notes/commit/35ed993ce4e453c78f3f887f813ce52ddeeada77))
* **shared:** add v1 API-contract types and round-trip tests ([e80c138](https://github.com/cedricziel/robot-notes/commit/e80c138f2562d6ae5c01df2808fa7b84be89c027))


### Bug Fixes

* **docker:** strip server from workspace in web-builder stage ([726a56f](https://github.com/cedricziel/robot-notes/commit/726a56f23dd38f29189c68bc70f7a734fdcfc904))
* **docker:** unblock multi-arch image build ([94fd08d](https://github.com/cedricziel/robot-notes/commit/94fd08d27c0fcdd4cea92d11e0c6e2f364822719))
* **server:** defer middleware chain until first request ([a27a915](https://github.com/cedricziel/robot-notes/commit/a27a91573151259aabd2c9c98df01f48e671fd22))
* **server:** use package: imports in dart_frog entrypoint ([b934593](https://github.com/cedricziel/robot-notes/commit/b934593c7de1445abc0709e32702cb3029e0c75b))


### Documentation

* add RELEASING.md operator runbook ([f8215b6](https://github.com/cedricziel/robot-notes/commit/f8215b6c371797e9adf7c91d92a9c59160540a4d))
* add top-level README with quickstart ([7657fef](https://github.com/cedricziel/robot-notes/commit/7657fefdb4c1a9d7e6c05afeb2bf8629ff717eff))
* **mvp-foundation:** commit to dart pub workspace + shared API-contract package ([8ff77ef](https://github.com/cedricziel/robot-notes/commit/8ff77ef1a9b9673074dbde1aed786479f633e725))
* **readme:** add server, app, Docker, and agent-onboarding usage ([58c4dc0](https://github.com/cedricziel/robot-notes/commit/58c4dc04c35a6ba6996e0c9fc08f0b3bf18e66e6))
* scaffold MVP foundation change with Apache 2.0 license ([14218ed](https://github.com/cedricziel/robot-notes/commit/14218ed2b01d2463c8f3838ec4d8d8285f3dc56b))
* **server:** add API.md and STORAGE.md operator references ([3e7fd65](https://github.com/cedricziel/robot-notes/commit/3e7fd65b37b763c020aab5f17ad0f7854cd2545a))


### Miscellaneous

* release as 0.1.0 ([2c142cf](https://github.com/cedricziel/robot-notes/commit/2c142cf70932fb4cfd817ee369b64ff0a17c386c))
