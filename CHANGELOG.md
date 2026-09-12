# Changelog

## [0.1.3](https://github.com/cedricziel/robot-notes/compare/v0.1.2...v0.1.3) (2026-09-12)


### Features

* **app:** add a refresh action to the list ([#90](https://github.com/cedricziel/robot-notes/issues/90)) ([d4a52f1](https://github.com/cedricziel/robot-notes/commit/d4a52f1de92cf0c9714392ca721671e528f64be0))
* **app:** confirm before discarding unsaved edits ([#89](https://github.com/cedricziel/robot-notes/issues/89)) ([b159213](https://github.com/cedricziel/robot-notes/commit/b159213282c9effa0f204cbb886f0ade9d95361a))
* **app:** delete a note from the note screen ([#93](https://github.com/cedricziel/robot-notes/issues/93)) ([45d0323](https://github.com/cedricziel/robot-notes/commit/45d032399ada48b5b287a6f8aa518723b00cc967))
* **app:** delete a note from the notes list ([#102](https://github.com/cedricziel/robot-notes/issues/102)) ([def7bf5](https://github.com/cedricziel/robot-notes/commit/def7bf50eb1d75ccbd3d34be69240ff0903bc880))
* **app:** keyboard shortcuts in the note editor ([#100](https://github.com/cedricziel/robot-notes/issues/100)) ([5270083](https://github.com/cedricziel/robot-notes/commit/52700831a3f32dbec8b03c8237d502b916c6a570))
* **app:** let the user merge by hand in the conflict view ([#94](https://github.com/cedricziel/robot-notes/issues/94)) ([0d63c75](https://github.com/cedricziel/robot-notes/commit/0d63c75fdf2e23a4f9b30919567babd0e1e48625))
* **app:** open freshly created notes in edit mode ([#99](https://github.com/cedricziel/robot-notes/issues/99)) ([492259c](https://github.com/cedricziel/robot-notes/commit/492259c3e2f1a70105bf2b56e137c4995502b1f0))
* **app:** render note content as Markdown in view mode ([#92](https://github.com/cedricziel/robot-notes/issues/92)) ([07641e8](https://github.com/cedricziel/robot-notes/commit/07641e819def6cc628c9c15853657ead7b07dd3f))
* **app:** ship the iOS and macOS apps via TestFlight and the App Store ([f765db5](https://github.com/cedricziel/robot-notes/commit/f765db557271a9763312e82caf49d8af94c7b52a))
* **app:** show the realtime connection state in the notes list ([#97](https://github.com/cedricziel/robot-notes/issues/97)) ([4107dda](https://github.com/cedricziel/robot-notes/commit/4107dda4181ce8947fe38d9e73c1efa0a20b0f04))
* **ci:** publish rolling :main docker tag on push to main ([#77](https://github.com/cedricziel/robot-notes/issues/77)) ([f8272f3](https://github.com/cedricziel/robot-notes/commit/f8272f38ca79c45b6dd49508253c496b7e0ba83a))
* **server:** add MCP JSON-RPC core and note tools ([#71](https://github.com/cedricziel/robot-notes/issues/71)) ([e336952](https://github.com/cedricziel/robot-notes/commit/e336952b66e1f9c9615106bdad9e48b47fa7df64))
* **server:** add OAuth code and token stores ([#69](https://github.com/cedricziel/robot-notes/issues/69)) ([c7b252e](https://github.com/cedricziel/robot-notes/commit/c7b252e8a4b12bea9a37a4f4644b75641a277f80))
* **server:** add OAuth registration, consent, token, and revocation routes ([#70](https://github.com/cedricziel/robot-notes/issues/70)) ([5f9419e](https://github.com/cedricziel/robot-notes/commit/5f9419ed965e5eb1f49b17abffe90e3e35266117))
* **server:** add PKCE helper and OAuth client store ([#68](https://github.com/cedricziel/robot-notes/issues/68)) ([618b06d](https://github.com/cedricziel/robot-notes/commit/618b06d37e4411535c40a5a55de06318a12d4968))
* **server:** add public base URL and OAuth discovery documents ([#67](https://github.com/cedricziel/robot-notes/issues/67)) ([21fc679](https://github.com/cedricziel/robot-notes/commit/21fc67933161cb7bc3dbc2825ea62f004ea16351))
* **server:** declare MCP tool behavior annotations ([#82](https://github.com/cedricziel/robot-notes/issues/82)) ([f0dfca0](https://github.com/cedricziel/robot-notes/commit/f0dfca08daaaad6bb1a201d921bf784e2837f49e))
* **server:** serve MCP at /mcp with OAuth and static-key auth ([#72](https://github.com/cedricziel/robot-notes/issues/72)) ([8a7089d](https://github.com/cedricziel/robot-notes/commit/8a7089d8f512988ddcde0f0606196eb352b4af44))


### Bug Fixes

* **app:** drop the dart:io import from the setup flow ([#98](https://github.com/cedricziel/robot-notes/issues/98)) ([9663d5b](https://github.com/cedricziel/robot-notes/commit/9663d5be88c161371d5265d6653e45f02c0b840f))
* **app:** enable accessibility semantics on web ([#96](https://github.com/cedricziel/robot-notes/issues/96)) ([d2246b5](https://github.com/cedricziel/robot-notes/commit/d2246b5e275f22aee169bbea7f2f7dda93507d9d))
* **app:** keep the caret when syncing editor buffers ([#83](https://github.com/cedricziel/robot-notes/issues/83)) ([882673f](https://github.com/cedricziel/robot-notes/commit/882673fe4010e14374dbe9e11c5356ad2b46bbbd))
* **app:** open the realtime websocket with the platform-agnostic channel ([#85](https://github.com/cedricziel/robot-notes/issues/85)) ([6c7eb84](https://github.com/cedricziel/robot-notes/commit/6c7eb84cead465aaa89b93df40273712c3f628fd))
* **app:** re-fetch the note after acquiring the edit lock ([#87](https://github.com/cedricziel/robot-notes/issues/87)) ([e80b900](https://github.com/cedricziel/robot-notes/commit/e80b900f80fbddbcd048adc2a31666087e45cf4f))
* **app:** show list and search errors ([#84](https://github.com/cedricziel/robot-notes/issues/84)) ([68d7b7f](https://github.com/cedricziel/robot-notes/commit/68d7b7f15abf10babb448592dbfba262eda5dde7))
* **app:** show note timestamps in local time ([#88](https://github.com/cedricziel/robot-notes/issues/88)) ([ed54800](https://github.com/cedricziel/robot-notes/commit/ed5480032465ed5ad6e8a404fe47a7e52ee4aeee))
* **app:** surface save errors and confirm saves ([#91](https://github.com/cedricziel/robot-notes/issues/91)) ([46ce599](https://github.com/cedricziel/robot-notes/commit/46ce599852c27e6712ef07150141e49e6c12df0b))
* **app:** wire the note close button ([#86](https://github.com/cedricziel/robot-notes/issues/86)) ([98b8c90](https://github.com/cedricziel/robot-notes/commit/98b8c90552e9c17dda235fe084dda9509dc7aea6))
* **server:** drop form-action from the consent page CSP ([#81](https://github.com/cedricziel/robot-notes/issues/81)) ([8bb1a98](https://github.com/cedricziel/robot-notes/commit/8bb1a98e607f65a58e8a1c9f5b78abb7f5af9a36))
* **server:** harden OAuth registration, token, and revocation endpoints ([#73](https://github.com/cedricziel/robot-notes/issues/73)) ([a27553f](https://github.com/cedricziel/robot-notes/commit/a27553f0a5e4376e41a4540f730e64168c775d54))
* **server:** harden OAuth routes, client auth, and public URL handling ([#78](https://github.com/cedricziel/robot-notes/issues/78)) ([21e91ac](https://github.com/cedricziel/robot-notes/commit/21e91ac7d706f177c91d01239f02ce19acd1c823))
* **server:** validate MCP note ids, tighten origin checks, and share the /mcp chain ([#76](https://github.com/cedricziel/robot-notes/issues/76)) ([4375d51](https://github.com/cedricziel/robot-notes/commit/4375d51df09c978d950028d26337be1ecd5c454e))


### Documentation

* document the main image tag and TrueNAS SCALE deployment ([#80](https://github.com/cedricziel/robot-notes/issues/80)) ([d44d637](https://github.com/cedricziel/robot-notes/commit/d44d63731a68a907d9f71973efd31a69b69d6d9d))
* **openspec:** propose add-mcp-server change ([#66](https://github.com/cedricziel/robot-notes/issues/66)) ([138f48a](https://github.com/cedricziel/robot-notes/commit/138f48a2dce6aae60abf08ef013b70a0be635b4b))

## [0.1.2](https://github.com/cedricziel/robot-notes/compare/v0.1.1...v0.1.2) (2026-05-06)


### Bug Fixes

* **app:** don't return a Future from _BootstrapState setState callbacks ([3f1ed81](https://github.com/cedricziel/robot-notes/commit/3f1ed8196920d50c8f814c076d592ca134704227))
* **app:** grant keychain-access-groups entitlement so secure storage works ([d1b9e31](https://github.com/cedricziel/robot-notes/commit/d1b9e31ad18ad0234877fff174f1a48241d6ef85))

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
