# Changelog

## [0.2.16](https://github.com/cedricziel/robot-notes/compare/v0.2.15...v0.2.16) (2026-09-20)


### Features

* **app:** lock the app with Face ID / Touch ID via the account sheet ([#294](https://github.com/cedricziel/robot-notes/issues/294)) ([a8ae31c](https://github.com/cedricziel/robot-notes/commit/a8ae31cbecda709afd5f025f5e34f8b903001287))

## [0.2.15](https://github.com/cedricziel/robot-notes/compare/v0.2.14...v0.2.15) (2026-09-19)


### Features

* **app,server:** add OIDC sign-in on iOS and Android via a browser sheet ([#291](https://github.com/cedricziel/robot-notes/issues/291)) ([3ccf0f1](https://github.com/cedricziel/robot-notes/commit/3ccf0f1ea9dc8cde3f7a782b827ed0e2dae0b65b))

## [0.2.14](https://github.com/cedricziel/robot-notes/compare/v0.2.13...v0.2.14) (2026-09-18)


### Features

* **app:** adaptive spinners for database screens ([#289](https://github.com/cedricziel/robot-notes/issues/289)) ([8af7a39](https://github.com/cedricziel/robot-notes/commit/8af7a399125215aae8995e3ed892eefdff034f31))
* **app:** database property editors ([#279](https://github.com/cedricziel/robot-notes/issues/279)) ([3868470](https://github.com/cedricziel/robot-notes/commit/3868470f165b6b9cd3e5224929151ccbafc8af4a))
* **app:** database schema editor, new-database form, and real PropertyEditor in the table view ([#285](https://github.com/cedricziel/robot-notes/issues/285)) ([6c64e0c](https://github.com/cedricziel/robot-notes/commit/6c64e0c7decc3e049a6b331e451342900d1fe0ef))
* **app:** database screen — scaffold, table/list/board views, New row flow ([#281](https://github.com/cedricziel/robot-notes/issues/281)) ([f6620ae](https://github.com/cedricziel/robot-notes/commit/f6620ae8d6814ad810b9c2b3bc0d2b27c4b31b8f))
* **app:** note property panel, database embeds, sidebar wrap-up ([#286](https://github.com/cedricziel/robot-notes/issues/286)) ([89ca4a6](https://github.com/cedricziel/robot-notes/commit/89ca4a6bf88a5c5b7b18e8cadcd4e183b37148e2))
* **app:** pull-to-refresh and macOS menu bar for database screens ([#290](https://github.com/cedricziel/robot-notes/issues/290)) ([f592267](https://github.com/cedricziel/robot-notes/commit/f5922672e416c4c5e34d170c0105fafe89e5577d))
* **databases:** add MCP tools for database CRUD, query, rows, and property patches ([#283](https://github.com/cedricziel/robot-notes/issues/283)) ([655546c](https://github.com/cedricziel/robot-notes/commit/655546c316ac18e047205c42cda3cd14316dbef7))
* **databases:** REST routes for note properties and databases ([#284](https://github.com/cedricziel/robot-notes/issues/284)) ([bdbc38c](https://github.com/cedricziel/robot-notes/commit/bdbc38cd3dc05e5e4088962a260123e178ff7ac5))
* **databases:** write path — Storage.patchExtra, NoteWriteService validation, rows, relations ([#282](https://github.com/cedricziel/robot-notes/issues/282)) ([2bab1ad](https://github.com/cedricziel/robot-notes/commit/2bab1ad5fed915bb12a60680fd49130669243cac))


### Documentation

* **openspec:** archive add-databases and add-database-views ([#288](https://github.com/cedricziel/robot-notes/issues/288)) ([5208a19](https://github.com/cedricziel/robot-notes/commit/5208a19de37b3701a88264493d724d5c16aea619))

## [0.2.13](https://github.com/cedricziel/robot-notes/compare/v0.2.12...v0.2.13) (2026-09-18)


### Features

* **app,server:** database screen routing ([#274](https://github.com/cedricziel/robot-notes/issues/274)) ([9589a76](https://github.com/cedricziel/robot-notes/commit/9589a7610e850a1703c10472e6b854d6e27276c6))
* **app:** add database endpoints to RobotNotesClient ([#272](https://github.com/cedricziel/robot-notes/issues/272)) ([b036f94](https://github.com/cedricziel/robot-notes/commit/b036f94f328b7fdec7382e84d0e225e393efe98c))
* **app:** add listDatabases/getDatabase/createDatabase/updateDatabase/ ([b036f94](https://github.com/cedricziel/robot-notes/commit/b036f94f328b7fdec7382e84d0e225e393efe98c))
* **app:** database-views controllers ([#278](https://github.com/cedricziel/robot-notes/issues/278)) ([67252f4](https://github.com/cedricziel/robot-notes/commit/67252f42accd14d96b0b2a8d9f9e0febad8447a6))
* **app:** database-views spike, error mapping, TitleSearchService ([#269](https://github.com/cedricziel/robot-notes/issues/269)) ([0324a84](https://github.com/cedricziel/robot-notes/commit/0324a8427b956ffb14b708d4910caa1d45d17d6c))
* **app:** native iOS and macOS experience ([#267](https://github.com/cedricziel/robot-notes/issues/267)) ([692ecca](https://github.com/cedricziel/robot-notes/commit/692ecca1b2fde6676cfcfa839ad49d95d82613dd))
* **app:** touch gestures for the notes list, note view, and search sheet ([#228](https://github.com/cedricziel/robot-notes/issues/228)) ([ddbe7c6](https://github.com/cedricziel/robot-notes/commit/ddbe7c684249b5135d6a22d7f134718c28a6e182))
* **databases:** definition parsing, validation, and registry ([#273](https://github.com/cedricziel/robot-notes/issues/273)) ([aab1c90](https://github.com/cedricziel/robot-notes/commit/aab1c906690a62184e5d6dec45318c5900b994c1))
* **databases:** property index in SQLite and query compiler ([#277](https://github.com/cedricziel/robot-notes/issues/277)) ([589a33c](https://github.com/cedricziel/robot-notes/commit/589a33cff78e8ccefd502372eb0b4baa5520bfdf))
* **databases:** shared contracts, DTOs, routes, error codes ([#270](https://github.com/cedricziel/robot-notes/issues/270)) ([1bc1d33](https://github.com/cedricziel/robot-notes/commit/1bc1d337154ee142fdbf77205393bca4761a8576))
* **hermes-plugin:** append tool, remember path, documented tool parameters ([#262](https://github.com/cedricziel/robot-notes/issues/262)) ([405d0b2](https://github.com/cedricziel/robot-notes/commit/405d0b2b66f08643bdcc9e55fc590537ba968349))
* **hermes-plugin:** bundle a robot-notes skill with the provider ([#254](https://github.com/cedricziel/robot-notes/issues/254)) ([d49f5ba](https://github.com/cedricziel/robot-notes/commit/d49f5ba502e8709376a05ae649ff0a7f0e567e3f)), closes [#245](https://github.com/cedricziel/robot-notes/issues/245)
* **hermes-plugin:** circuit breaker and short recall timeout ([#258](https://github.com/cedricziel/robot-notes/issues/258)) ([e0ab373](https://github.com/cedricziel/robot-notes/commit/e0ab37343748a3e664d29503f6c9470e8694d1ae))
* **hermes-plugin:** pip entry point, manifest hooks, install docs ([#265](https://github.com/cedricziel/robot-notes/issues/265)) ([552fb9b](https://github.com/cedricziel/robot-notes/commit/552fb9b7d9ea73c9695d41f3751ecdb70c66ea42)), closes [#246](https://github.com/cedricziel/robot-notes/issues/246)
* **hermes-plugin:** scope recall per session and query, gate trivial prompts, report recall status ([#255](https://github.com/cedricziel/robot-notes/issues/255)) ([3b030ca](https://github.com/cedricziel/robot-notes/commit/3b030ca9526b341d125221ce2e98795681519941)), closes [#242](https://github.com/cedricziel/robot-notes/issues/242)
* **server:** add POST /notes/{id}/append ([#260](https://github.com/cedricziel/robot-notes/issues/260)) ([950dce9](https://github.com/cedricziel/robot-notes/commit/950dce9779436d0b642a16e04053a7b178ade442))
* **server:** filter GET /notes by title ([#259](https://github.com/cedricziel/robot-notes/issues/259)) ([4b91f7b](https://github.com/cedricziel/robot-notes/commit/4b91f7b1e0724d84fde0d78f60a63223f419b2d3)), closes [#234](https://github.com/cedricziel/robot-notes/issues/234)


### Bug Fixes

* **hermes-plugin:** do not write from subagent, cron or flush contexts ([#250](https://github.com/cedricziel/robot-notes/issues/250)) ([f5f8c72](https://github.com/cedricziel/robot-notes/commit/f5f8c725228998c680eb534b87eb0dbe46167a3c)), closes [#236](https://github.com/cedricziel/robot-notes/issues/236)
* **hermes-plugin:** file a readable bounded transcript at session end ([#256](https://github.com/cedricziel/robot-notes/issues/256)) ([1427872](https://github.com/cedricziel/robot-notes/commit/1427872c962f8fff36d9dbcb84291e17b1be2b58)), closes [#240](https://github.com/cedricziel/robot-notes/issues/240)
* **hermes-plugin:** follow the Hermes threading and secret contracts ([#263](https://github.com/cedricziel/robot-notes/issues/263)) ([fabd011](https://github.com/cedricziel/robot-notes/commit/fabd0110103c9d114775724568b4af1af8d2156e)), closes [#241](https://github.com/cedricziel/robot-notes/issues/241)
* **hermes-plugin:** map server error codes precisely and keep the envelope ([#253](https://github.com/cedricziel/robot-notes/issues/253)) ([175c7cf](https://github.com/cedricziel/robot-notes/commit/175c7cfa2efeae55c3f6dc1d0873c67f75eba517))
* **hermes-plugin:** mirror memory replace/remove as entry edits ([#261](https://github.com/cedricziel/robot-notes/issues/261)) ([1cd1557](https://github.com/cedricziel/robot-notes/commit/1cd1557f4d49ff931c0e904a321df5dc83971c6e)), closes [#237](https://github.com/cedricziel/robot-notes/issues/237)
* **hermes-plugin:** paginate find_note_by_title ([#252](https://github.com/cedricziel/robot-notes/issues/252)) ([54ff1ad](https://github.com/cedricziel/robot-notes/commit/54ff1adbf6f9b72dab27d8ad7a9aff93ca6b85ad)), closes [#239](https://github.com/cedricziel/robot-notes/issues/239)
* **hermes-plugin:** rebind session id on on_session_switch ([#249](https://github.com/cedricziel/robot-notes/issues/249)) ([40a426b](https://github.com/cedricziel/robot-notes/commit/40a426b1f206d206dd42dab3b50f2fe684e03066)), closes [#235](https://github.com/cedricziel/robot-notes/issues/235)
* **hermes-plugin:** sync MemoryProvider stub with upstream and add compat shim ([#251](https://github.com/cedricziel/robot-notes/issues/251)) ([fe6c80f](https://github.com/cedricziel/robot-notes/commit/fe6c80ffec1be2e74f9f85fce6f749f87dd3de5c))
* **server:** accept content-only PUT /notes/{id} and add a live-server e2e suite ([#264](https://github.com/cedricziel/robot-notes/issues/264)) ([b55a9a9](https://github.com/cedricziel/robot-notes/commit/b55a9a9979e1717fc3a5b4bee74da501ce6d50e0))


### Documentation

* **hermes-plugin:** prepare plugin-catalog submission ([#275](https://github.com/cedricziel/robot-notes/issues/275)) ([ef14042](https://github.com/cedricziel/robot-notes/commit/ef1404200614bd7db18213bd47242a12a097a70e)), closes [#247](https://github.com/cedricziel/robot-notes/issues/247)
* **openspec:** propose add-databases and add-database-views ([#268](https://github.com/cedricziel/robot-notes/issues/268)) ([a4d4688](https://github.com/cedricziel/robot-notes/commit/a4d46888ac25cd9de98cd3fa23e917d591c6e637))
* **server:** document the error body shape routes actually emit ([#271](https://github.com/cedricziel/robot-notes/issues/271)) ([6320d5e](https://github.com/cedricziel/robot-notes/commit/6320d5ea4f6ca625aec0ce7ed02bf0d8ea27ea44)), closes [#257](https://github.com/cedricziel/robot-notes/issues/257)

## [0.2.12](https://github.com/cedricziel/robot-notes/compare/v0.2.11...v0.2.12) (2026-09-18)


### Features

* **app:** adaptive shell, notes list and note view redesign, shared status strips ([#224](https://github.com/cedricziel/robot-notes/issues/224)) ([2216794](https://github.com/cedricziel/robot-notes/commit/22167943739611b3a75a168b189c5e79709fd560))


### Bug Fixes

* **server:** make Ollama embeddings work for long and empty notes ([#225](https://github.com/cedricziel/robot-notes/issues/225)) ([acd7a0b](https://github.com/cedricziel/robot-notes/commit/acd7a0bc4885cafdb70f2e96454fabcdba39e819))


### Documentation

* **server:** state nomic-embed-text's real 2048-token context under Ollama ([#226](https://github.com/cedricziel/robot-notes/issues/226)) ([86aa4b6](https://github.com/cedricziel/robot-notes/commit/86aa4b64e638c6f8b4f78e60639cde102557b442))

## [0.2.11](https://github.com/cedricziel/robot-notes/compare/v0.2.10...v0.2.11) (2026-09-13)


### Features

* **claude-plugin:** add hook to continuously log conversations to robot-notes ([#216](https://github.com/cedricziel/robot-notes/issues/216)) ([8233b30](https://github.com/cedricziel/robot-notes/commit/8233b30a78b51675d2c1039b445ce7740b4bd41b))
* **hermes-plugin:** add robotnotes_list to enumerate all notes ([#215](https://github.com/cedricziel/robot-notes/issues/215)) ([ef039b0](https://github.com/cedricziel/robot-notes/commit/ef039b0637b6f06dbb99c6506e81e9ad1411d0b6))
* **search:** add hybrid (keyword + semantic) search ([#218](https://github.com/cedricziel/robot-notes/issues/218)) ([5ba41dc](https://github.com/cedricziel/robot-notes/commit/5ba41dc04c0afe82156016c14cb4d061889f7331))
* **server/ws:** trace WebSocket messages as linked root spans ([#214](https://github.com/cedricziel/robot-notes/issues/214)) ([b4885cb](https://github.com/cedricziel/robot-notes/commit/b4885cbc477650d8285ddcaa52cdbd90442c4ed7))


### Bug Fixes

* **server:** tolerate natural-language punctuation in search queries ([#217](https://github.com/cedricziel/robot-notes/issues/217)) ([69b9421](https://github.com/cedricziel/robot-notes/commit/69b9421388e77c8b7ebc004bd479c5ecfe3658ce))

## [0.2.10](https://github.com/cedricziel/robot-notes/compare/v0.2.9...v0.2.10) (2026-09-13)


### Features

* **app:** add file upload — client API, file picker, and FAB wiring ([#211](https://github.com/cedricziel/robot-notes/issues/211)) ([e8a4332](https://github.com/cedricziel/robot-notes/commit/e8a4332aad0875fddc7fa027f5c940264ea1cedd))
* **hermes-plugin:** robot-notes memory provider for Hermes Agent ([#199](https://github.com/cedricziel/robot-notes/issues/199)) ([65556e3](https://github.com/cedricziel/robot-notes/commit/65556e3cabcbfb674c340eda003f0588c5c45a66))
* **plugins:** add robot-notes and hermes-agent plugins, version alongside project ([#203](https://github.com/cedricziel/robot-notes/issues/203)) ([4d2cfeb](https://github.com/cedricziel/robot-notes/commit/4d2cfeb650d5540e7f7f4ea93947a2d31eacd4fd))
* **server:** add a configurable max upload size setting ([#191](https://github.com/cedricziel/robot-notes/issues/191)) ([cf2d778](https://github.com/cedricziel/robot-notes/commit/cf2d77865c4c22fd6c4dd14397c4de9133549e01))
* **server:** add attachment write helper (sanitization, collision, atomic write) ([#192](https://github.com/cedricziel/robot-notes/issues/192)) ([e1d723f](https://github.com/cedricziel/robot-notes/commit/e1d723ff18bc8ced9dd19557f0fbb0a41a241da1))
* **server:** add POST/GET /notes/files and folder listing ([#205](https://github.com/cedricziel/robot-notes/issues/205)) ([1e59b18](https://github.com/cedricziel/robot-notes/commit/1e59b182ad678e51352177584e31a421d4d0759f))
* **server:** add request_upload and finalize_upload MCP tools ([#210](https://github.com/cedricziel/robot-notes/issues/210)) ([a266311](https://github.com/cedricziel/robot-notes/commit/a266311a783bb4ad2455fe703554f877e7614446))
* **server:** add upload-session store and PUT /notes/file-uploads/{token} ([#206](https://github.com/cedricziel/robot-notes/issues/206)) ([8bd640e](https://github.com/cedricziel/robot-notes/commit/8bd640e11d61832ab1024a9ce8b9be5698e6a2a7))
* **server:** index uploaded files for folder-tree discoverability ([#204](https://github.com/cedricziel/robot-notes/issues/204)) ([3aaa803](https://github.com/cedricziel/robot-notes/commit/3aaa8035314bfb7dc41b829a6e3a42285b627a40))


### Bug Fixes

* **hermes-plugin:** relative imports and correct search query param ([#200](https://github.com/cedricziel/robot-notes/issues/200)) ([c041796](https://github.com/cedricziel/robot-notes/commit/c041796be510aa364697f9ff856a5a61295d58a3))


### Documentation

* **server:** document vault-files, upload sessions, and the two upload paths ([#212](https://github.com/cedricziel/robot-notes/issues/212)) ([7d7e35d](https://github.com/cedricziel/robot-notes/commit/7d7e35dc171bda8066522950e1ca246465055408))

## [0.2.9](https://github.com/cedricziel/robot-notes/compare/v0.2.8...v0.2.9) (2026-09-13)


### Features

* **app:** add a "New folder" action to the sidebar ([#182](https://github.com/cedricziel/robot-notes/issues/182)) ([0ac2ca2](https://github.com/cedricziel/robot-notes/commit/0ac2ca26e32a55edbe11e4c5afa5981029d03201))
* **app:** add macOS tray so the app can stay in the background ([#187](https://github.com/cedricziel/robot-notes/issues/187)) ([c03ec08](https://github.com/cedricziel/robot-notes/commit/c03ec0836f28c51e99e06afb2b4394e12d307ac6))
* **app:** turn the notes list FAB into a New note / New folder menu ([#183](https://github.com/cedricziel/robot-notes/issues/183)) ([24e891d](https://github.com/cedricziel/robot-notes/commit/24e891d8bc7dd1f07890ebb2caa5973909f40c2d))
* **server:** add create_folder MCP tool ([#181](https://github.com/cedricziel/robot-notes/issues/181)) ([dd23cd8](https://github.com/cedricziel/robot-notes/commit/dd23cd873a7760411c003ce8e103d6310fc1087e))
* **server:** add POST /notes/tree to create empty folders ([#180](https://github.com/cedricziel/robot-notes/issues/180)) ([d9d158f](https://github.com/cedricziel/robot-notes/commit/d9d158f565a54d8ef804b31800814f42e543c833))
* **server:** scan for empty-folder marker files on startup ([#179](https://github.com/cedricziel/robot-notes/issues/179)) ([ef4c879](https://github.com/cedricziel/robot-notes/commit/ef4c879c42a5c6b0f8720ffdd00ea6f1ccf3cd1d))
* **server:** tag /mcp error spans with why the request was rejected ([#189](https://github.com/cedricziel/robot-notes/issues/189)) ([1b1667e](https://github.com/cedricziel/robot-notes/commit/1b1667e8eea9ca7b798aa8e1ce1ef9caac58bd92))


### Bug Fixes

* **server:** point _span_test_helpers at flutter_otel_sdk's SdkTracer ([#190](https://github.com/cedricziel/robot-notes/issues/190)) ([cd6fb55](https://github.com/cedricziel/robot-notes/commit/cd6fb55e49b26be82c5678de4c8d5788043aebea))


### Documentation

* **openspec:** route FAB folder/note creation through add-empty-folder-creation ([#178](https://github.com/cedricziel/robot-notes/issues/178)) ([638a6c2](https://github.com/cedricziel/robot-notes/commit/638a6c294157e18bd7bee7cd8b2a056fe55b9c43))
* **server:** document the empty-folder marker file and POST /notes/tree ([#185](https://github.com/cedricziel/robot-notes/issues/185)) ([b4684cc](https://github.com/cedricziel/robot-notes/commit/b4684cc55330d7403e25d94a7392b5a4514826a7))

## [0.2.8](https://github.com/cedricziel/robot-notes/compare/v0.2.7...v0.2.8) (2026-09-13)


### Bug Fixes

* **app:** bump flutter-otel pin to the SwiftPM plugin fix ([#176](https://github.com/cedricziel/robot-notes/issues/176)) ([76886ab](https://github.com/cedricziel/robot-notes/commit/76886ab041048ec0624e31fcb8a60280e725dd73))
* **server:** stop recording WebSocket upgrades as span errors ([#177](https://github.com/cedricziel/robot-notes/issues/177)) ([576ebc8](https://github.com/cedricziel/robot-notes/commit/576ebc821358f2b1946d7586889e383e5e187f17))

## [0.2.7](https://github.com/cedricziel/robot-notes/compare/v0.2.6...v0.2.7) (2026-09-13)


### Features

* **app:** distinguish TestFlight from production in deployment.environment.name ([#174](https://github.com/cedricziel/robot-notes/issues/174)) ([f07e728](https://github.com/cedricziel/robot-notes/commit/f07e728c491b886e227cc18d14009fd0e4b8804c))
* **server:** brand the OAuth consent page, show the redirect destination, add a Cancel link ([#172](https://github.com/cedricziel/robot-notes/issues/172)) ([737f161](https://github.com/cedricziel/robot-notes/commit/737f1614ecd8b5fd6990fe85e23f618236aaa776))

## [0.2.6](https://github.com/cedricziel/robot-notes/compare/v0.2.5...v0.2.6) (2026-09-13)


### Features

* **app:** cap setup screen width, add live reachability check, tuck manual key entry behind disclosure ([#171](https://github.com/cedricziel/robot-notes/issues/171)) ([f378dee](https://github.com/cedricziel/robot-notes/commit/f378dee47d59ac442676da63d555bf2607b2b6de))
* **app:** present search as an overlay with a Recent-notes empty state ([#170](https://github.com/cedricziel/robot-notes/issues/170)) ([9a0bf13](https://github.com/cedricziel/robot-notes/commit/9a0bf13a4c8867e0570a94c18461a1d5b2f85fec))
* enrich OTel resource attributes on server and app ([#169](https://github.com/cedricziel/robot-notes/issues/169)) ([93b9b2c](https://github.com/cedricziel/robot-notes/commit/93b9b2c40bfc55034eff388f4b095793d4853e49))


### Documentation

* **openspec:** archive merged notes-list and note-editor-autosave changes ([#167](https://github.com/cedricziel/robot-notes/issues/167)) ([6e91df4](https://github.com/cedricziel/robot-notes/commit/6e91df404aeda40102ab7c8649efd59b04c95c9a))

## [0.2.5](https://github.com/cedricziel/robot-notes/compare/v0.2.4...v0.2.5) (2026-09-13)


### Features

* **app,server:** notes-list excerpt, tags, and desktop polish ([#159](https://github.com/cedricziel/robot-notes/issues/159)) ([fa39299](https://github.com/cedricziel/robot-notes/commit/fa392992439f1c01ead007e0b77ce9014bf31f36))
* **app:** add a formatting toolbar and split live preview to edit mode ([#163](https://github.com/cedricziel/robot-notes/issues/163)) ([9be52da](https://github.com/cedricziel/robot-notes/commit/9be52daa4a7e420ca7783dd8d801f8631826417c))
* **app:** autosave note edits, replace discard prompt with flush-on-close ([#165](https://github.com/cedricziel/robot-notes/issues/165)) ([7b15a2a](https://github.com/cedricziel/robot-notes/commit/7b15a2a7cea66cdeffdb1e0c1964ebfff6ccba16))
* **app:** replace the narrow-layout icon row with a bottom nav ([#161](https://github.com/cedricziel/robot-notes/issues/161)) ([d386616](https://github.com/cedricziel/robot-notes/commit/d38661651fb6170ed72f175fe685fcb0ad59d6bb))
* **app:** show note metadata, cap reading width, collapse empty backlinks ([#162](https://github.com/cedricziel/robot-notes/issues/162)) ([d92b87a](https://github.com/cedricziel/robot-notes/commit/d92b87a9f54f478120f0395c110ce987e77109ee))

## [0.2.4](https://github.com/cedricziel/robot-notes/compare/v0.2.3...v0.2.4) (2026-09-12)


### Features

* **app:** trace outbound server calls with OTel client spans ([#164](https://github.com/cedricziel/robot-notes/issues/164)) ([865e44c](https://github.com/cedricziel/robot-notes/commit/865e44c6321a5905dfde1664d625d144753cfebb))


### Bug Fixes

* **server:** reject .. and empty path segments to close a traversal hole ([#160](https://github.com/cedricziel/robot-notes/issues/160)) ([706fbee](https://github.com/cedricziel/robot-notes/commit/706fbee4d31a781d68f327686a37bce16a1451be))

## [0.2.3](https://github.com/cedricziel/robot-notes/compare/v0.2.2...v0.2.3) (2026-09-12)


### Features

* **app:** follow the OS light/dark setting automatically ([#153](https://github.com/cedricziel/robot-notes/issues/153)) ([0bdf198](https://github.com/cedricziel/robot-notes/commit/0bdf1987e4b0e6acb20e2b25f92e8cc21579f2c3))
* **app:** split the setup wizard into a server step and a login step ([#156](https://github.com/cedricziel/robot-notes/issues/156)) ([869ca80](https://github.com/cedricziel/robot-notes/commit/869ca802dc230da5a2228fe894f098bdfbf73c82))
* **server:** add OTel trace export alongside the existing log pipeline ([#148](https://github.com/cedricziel/robot-notes/issues/148)) ([2fbc43e](https://github.com/cedricziel/robot-notes/commit/2fbc43ed5d6acc87163a72293a2dc2fbb450a4f1))
* **server:** trace and log MCP tool-call dispatch ([#154](https://github.com/cedricziel/robot-notes/issues/154)) ([17beef0](https://github.com/cedricziel/robot-notes/commit/17beef09c47655155b487f7c361be2b36214f3cb))
* **server:** trace note writes and log OAuth security events ([#157](https://github.com/cedricziel/robot-notes/issues/157)) ([ccb3f7c](https://github.com/cedricziel/robot-notes/commit/ccb3f7cb82eadb5b2b5eac7fcd954e148e765d15))
* **server:** trace search queries and log OAuth authorize/OIDC failures ([#152](https://github.com/cedricziel/robot-notes/issues/152)) ([57b2b3a](https://github.com/cedricziel/robot-notes/commit/57b2b3a83cf75ef638a0e7c005a7204aecd8fa19))
* **server:** wrap every request in a span and correlate logs to it ([#149](https://github.com/cedricziel/robot-notes/issues/149)) ([bc6f756](https://github.com/cedricziel/robot-notes/commit/bc6f756b2b4ba405e5dd1c91fe11187bde188018))


### Bug Fixes

* **app:** add a way to clear an active tag filter ([#143](https://github.com/cedricziel/robot-notes/issues/143)) ([e8b7565](https://github.com/cedricziel/robot-notes/commit/e8b7565790ecadd07a0e6f88b63e650f4b873190))
* **app:** show a real error, not "null", when create-note fails ([#142](https://github.com/cedricziel/robot-notes/issues/142)) ([266fc32](https://github.com/cedricziel/robot-notes/commit/266fc328a851a86d798933c62490f4b3b68c6152))
* **macos:** grant network.server entitlement to release builds ([#155](https://github.com/cedricziel/robot-notes/issues/155)) ([9350f1f](https://github.com/cedricziel/robot-notes/commit/9350f1f286693a26d6cfc2b245c88c8fae01d531))

## [0.2.2](https://github.com/cedricziel/robot-notes/compare/v0.2.1...v0.2.2) (2026-09-12)


### Bug Fixes

* **app:** use the web sign-in flow on web, not the desktop loopback ([#146](https://github.com/cedricziel/robot-notes/issues/146)) ([5adac3d](https://github.com/cedricziel/robot-notes/commit/5adac3d3a82db87fa1b38c03d8310cac84d937ef))

## [0.2.1](https://github.com/cedricziel/robot-notes/compare/v0.2.0...v0.2.1) (2026-09-12)


### Bug Fixes

* **server:** match lowercase ulids in the legacy layout migration ([#140](https://github.com/cedricziel/robot-notes/issues/140)) ([b3b012a](https://github.com/cedricziel/robot-notes/commit/b3b012ac1cbd8f96f70539cb37c6a259ea2c6ad0))

## [0.2.0](https://github.com/cedricziel/robot-notes/compare/v0.1.8...v0.2.0) (2026-09-12)


### ⚠ BREAKING CHANGES

* the on-disk note filename is no longer <id>.md. A startup migration renames existing legacy files to the new layout automatically (no manual steps), de-duplicating any collisions. See openspec/changes/add-vault-structure/ for the full spec, design, and task breakdown. This commit exists to correct the previous squash-merge commit ([#136](https://github.com/cedricziel/robot-notes/issues/136)), whose subject line was not a Conventional Commit and so was skipped by release-please's version computation.

### Features

* turn notes into a hierarchical Obsidian-style vault ([#138](https://github.com/cedricziel/robot-notes/issues/138)) ([cbdcbf0](https://github.com/cedricziel/robot-notes/commit/cbdcbf084338d6f7a06e430659cb5b862f3b2713))

## [0.1.8](https://github.com/cedricziel/robot-notes/compare/v0.1.7...v0.1.8) (2026-09-12)


### Features

* **app:** add OIDC sign-in as an alternative to pasting the API key ([#133](https://github.com/cedricziel/robot-notes/issues/133)) ([7736bea](https://github.com/cedricziel/robot-notes/commit/7736bead0a52094da57ecdcfea156f34529f4e63))
* **server:** accept scoped OAuth tokens on the REST API and WebSocket ([#130](https://github.com/cedricziel/robot-notes/issues/130)) ([d0bbedc](https://github.com/cedricziel/robot-notes/commit/d0bbedc6658c8aeb0ea536d67f05a169b8bf851f))
* **server:** add OIDC discovery, JWKS verification, and pending-login store ([#131](https://github.com/cedricziel/robot-notes/issues/131)) ([d72b7df](https://github.com/cedricziel/robot-notes/commit/d72b7dff33f73c2b87a1dd48a8451b05c7b7aa0b))
* **server:** add OIDC login and callback routes, wire into consent ([#132](https://github.com/cedricziel/robot-notes/issues/132)) ([5c52c21](https://github.com/cedricziel/robot-notes/commit/5c52c2128632aa4ef59d4dfa08c61a4086973b8e))


### Documentation

* document OIDC login coexistence model and consent flow ([#134](https://github.com/cedricziel/robot-notes/issues/134)) ([4584f51](https://github.com/cedricziel/robot-notes/commit/4584f51a8af777a0e2a47382c9e572f149068289))

## [0.1.7](https://github.com/cedricziel/robot-notes/compare/v0.1.6...v0.1.7) (2026-09-12)


### Features

* **app:** resolve OTel export config at runtime from the server ([4ace1fd](https://github.com/cedricziel/robot-notes/commit/4ace1fd58bb7dc3bbf767797505ebfd7215b32f9))
* **server:** serve runtime OTel export config at GET /otel-config ([62f9310](https://github.com/cedricziel/robot-notes/commit/62f9310b752efe5f7332971366070f87557ecbbb))


### Bug Fixes

* **server:** Vary: Accept on dual-use API/web paths ([#129](https://github.com/cedricziel/robot-notes/issues/129)) ([d27f09c](https://github.com/cedricziel/robot-notes/commit/d27f09c5f456db28184992eb897e678f55d2d71d))

## [0.1.6](https://github.com/cedricziel/robot-notes/compare/v0.1.5...v0.1.6) (2026-09-12)


### Features

* export logs via OpenTelemetry (server + app) ([#114](https://github.com/cedricziel/robot-notes/issues/114)) ([b9a169b](https://github.com/cedricziel/robot-notes/commit/b9a169bd58c1836b61d571244c11c6a08297f6c4))


### Bug Fixes

* **app:** make Cmd+S/Ctrl+S save reliably on web ([#126](https://github.com/cedricziel/robot-notes/issues/126)) ([a6e8f84](https://github.com/cedricziel/robot-notes/commit/a6e8f84a276ebc401bee5a6146d27569e99d521a))

## [0.1.5](https://github.com/cedricziel/robot-notes/compare/v0.1.4...v0.1.5) (2026-09-12)


### Features

* Add RN lettermark logo and native splash screen ([#123](https://github.com/cedricziel/robot-notes/issues/123)) ([6fd8969](https://github.com/cedricziel/robot-notes/commit/6fd8969d7e8129e5dba4e26f4cc7fcf78199b871))


### Bug Fixes

* **app:** reflect pushed routes in the browser URL bar ([#124](https://github.com/cedricziel/robot-notes/issues/124)) ([37f2fcf](https://github.com/cedricziel/robot-notes/commit/37f2fcf898ee8f0e0e58b1346c91f20fcd08ddfe))
* **setup:** reject http:// server URLs before validating the API key ([#122](https://github.com/cedricziel/robot-notes/issues/122)) ([46fc216](https://github.com/cedricziel/robot-notes/commit/46fc216686112d8263e4c55cb2d255784cbe628a)), closes [#119](https://github.com/cedricziel/robot-notes/issues/119)
* **tooling:** install pre-commit hook from git worktrees ([#120](https://github.com/cedricziel/robot-notes/issues/120)) ([4d90bb7](https://github.com/cedricziel/robot-notes/commit/4d90bb7583ef8e979a400870f6252d157b8e2a17))
* **tooling:** unset git env vars before pre-commit checks ([#118](https://github.com/cedricziel/robot-notes/issues/118)) ([dd0748c](https://github.com/cedricziel/robot-notes/commit/dd0748c28db4c4a4f79cf4684b0ee959a9a31304))

## [0.1.4](https://github.com/cedricziel/robot-notes/compare/v0.1.3...v0.1.4) (2026-09-12)


### Features

* make the search screen more helpful ([#108](https://github.com/cedricziel/robot-notes/issues/108)) ([d6e2ea1](https://github.com/cedricziel/robot-notes/commit/d6e2ea157fa18ca5e3724091e43dccc56bf17903))


### Miscellaneous

* release 0.1.4 ([d45d677](https://github.com/cedricziel/robot-notes/commit/d45d6771c83153e2b6f4695170a5d9747bd8fc8e))

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
