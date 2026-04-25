.PHONY: help install hooks fmt format lint analyze test test-shared test-server test-app run-server run-app outdated upgrade clean

# Default target prints the help table
help:
	@printf "robot-notes — workspace targets\n"
	@printf "\n"
	@printf "  install        dart pub get at the workspace root\n"
	@printf "  hooks          install the dart_pre_commit git hook\n"
	@printf "  fmt / format   dart format on the whole tree\n"
	@printf "  lint / analyze dart analyze on the whole workspace\n"
	@printf "  test           run every package's test suite\n"
	@printf "  test-shared    run shared/ tests only\n"
	@printf "  test-server    run server/ tests only\n"
	@printf "  test-app       run app/ Flutter tests only\n"
	@printf "  run-server     start the Dart Frog dev server\n"
	@printf "  run-app        start the Flutter app on the default device\n"
	@printf "  outdated       dart pub outdated --no-dev-dependencies\n"
	@printf "  upgrade        dart pub upgrade across the workspace\n"
	@printf "  clean          dart clean + flutter clean\n"

install:
	dart pub get

hooks:
	dart run tool/setup_git_hooks.dart

fmt format:
	dart format .

lint analyze:
	dart analyze

test:
	$(MAKE) test-shared
	$(MAKE) test-server
	$(MAKE) test-app

test-shared:
	cd shared && dart test

test-server:
	cd server && dart test

test-app:
	cd app && flutter test

run-server:
	cd server && dart_frog dev

run-app:
	cd app && flutter run

outdated:
	dart pub outdated --no-dev-dependencies

upgrade:
	dart pub upgrade

clean:
	dart pub cache clean -f || true
	rm -rf .dart_tool */.dart_tool app/build
