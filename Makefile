.PHONY: help install hooks fmt format lint analyze test test-shared test-server test-app run-server run-app web-build outdated upgrade clean docker-build

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
	@printf "  run-server     start the Dart Frog dev server (with dev defaults)\n"
	@printf "  run-app        start the Flutter app on the default device\n"
	@printf "  web-build      build the Flutter web bundle into app/build/web\n"
	@printf "  docker-build   build the server container image (multi-stage)\n"
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

# `make run-server` boots the Dart Frog dev server with dev defaults.
# Override any of these on the command line (e.g.
# `make run-server ROBOT_NOTES_API_KEY=mine`) or by exporting the env
# var before invoking make. The web bundle path is set automatically if
# `app/build/web/index.html` exists — run `make web-build` once first
# if you want the SPA served at /.
ROBOT_NOTES_API_KEY ?= dev-secret-do-not-ship
ROBOT_NOTES_DATA_DIR ?= $(CURDIR)/.dev-data
ROBOT_NOTES_PORT ?= 8080

run-server:
	@if [ -f app/build/web/index.html ]; then \
	  webdir="$(CURDIR)/app/build/web"; \
	  echo "==> serving Flutter web bundle from $$webdir"; \
	else \
	  webdir=""; \
	  echo "==> no app/build/web bundle; running API-only (run \`make web-build\` to serve the SPA)"; \
	fi; \
	mkdir -p "$(ROBOT_NOTES_DATA_DIR)"; \
	cd server && \
	  ROBOT_NOTES_API_KEY="$(ROBOT_NOTES_API_KEY)" \
	  ROBOT_NOTES_DATA_DIR="$(ROBOT_NOTES_DATA_DIR)" \
	  ROBOT_NOTES_PORT="$(ROBOT_NOTES_PORT)" \
	  ROBOT_NOTES_WEB_DIR="$$webdir" \
	  dart_frog dev

run-app:
	cd app && flutter run

web-build:
	cd app && flutter build web --release --no-tree-shake-icons

# The Dockerfile imports the shared/ workspace package via path dependency,
# so the build context MUST be the repo root, not server/.
docker-build:
	docker build -f server/Dockerfile -t robot-notes-server:dev \
	  --build-arg VERSION=$$(git describe --tags --always --dirty 2>/dev/null || echo dev) \
	  --build-arg VCS_REF=$$(git rev-parse HEAD 2>/dev/null || echo unknown) \
	  --build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
	  .

outdated:
	dart pub outdated --no-dev-dependencies

upgrade:
	dart pub upgrade

clean:
	dart pub cache clean -f || true
	rm -rf .dart_tool */.dart_tool app/build .dev-data
