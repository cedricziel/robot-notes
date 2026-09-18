.PHONY: help install hooks fmt format lint analyze test test-shared test-server test-app test-hermes-plugin test-hermes-plugin-contract test-hermes-plugin-e2e run-server run-app web-build outdated upgrade clean docker-build

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
	@printf "  test-hermes-plugin  run the Python hermes-plugin/ test suite (not part of \`test\`)\n"
	@printf "  test-hermes-plugin-contract  same, plus a pinned hermes-agent checkout on PYTHONPATH\n"
	@printf "  test-hermes-plugin-e2e  start a real server, run the hermes-plugin + Claude hook e2e suite against it, then stop it\n"
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

# Not part of `test`: this is the repo's only Python component (requires
# Python >=3.10), and Dart contributors shouldn't need a Python toolchain
# for the main suites.
HERMES_PLUGIN_PYTHON ?= $(shell command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3.10 || echo python3)

test-hermes-plugin:
	@$(HERMES_PLUGIN_PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || \
	  { echo "error: $(HERMES_PLUGIN_PYTHON) is older than the Python >=3.10 hermes-plugin/pyproject.toml requires; install python3.10+ (e.g. via Homebrew)"; exit 1; }
	cd hermes-plugin && \
	  ( test -d .venv || $(HERMES_PLUGIN_PYTHON) -m venv .venv ) && \
	  .venv/bin/pip install -q -e '.[dev]' && \
	  .venv/bin/python -m pytest

# Runs the same suite as `test-hermes-plugin`, but with a pinned hermes-agent checkout
# (see hermes-plugin/HERMES_AGENT_SHA) on PYTHONPATH, so tests/test_stub_parity.py and
# tests/test_memory_manager_contract.py exercise the real hermes-agent MemoryProvider
# ABC / MemoryManager instead of being skipped. Bare PYTHONPATH is enough — no extra
# pip install of hermes-agent's own dependencies is needed (see those tests' docstrings
# for why). Not part of `test` or `test-hermes-plugin`: it clones an external repo.
HERMES_AGENT_CHECKOUT ?= $(CURDIR)/hermes-plugin/.hermes-agent-checkout

test-hermes-plugin-contract:
	@$(HERMES_PLUGIN_PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || \
	  { echo "error: $(HERMES_PLUGIN_PYTHON) is older than the Python >=3.10 hermes-plugin/pyproject.toml requires; install python3.10+ (e.g. via Homebrew)"; exit 1; }
	@sha=$$(grep -vE '^[[:space:]]*(#|$$)' hermes-plugin/HERMES_AGENT_SHA | tr -d '[:space:]'); \
	  if [ -z "$$sha" ]; then echo "error: hermes-plugin/HERMES_AGENT_SHA has no pinned commit"; exit 1; fi; \
	  if [ ! -d "$(HERMES_AGENT_CHECKOUT)/.git" ]; then \
	    git init --quiet "$(HERMES_AGENT_CHECKOUT)"; \
	    git -C "$(HERMES_AGENT_CHECKOUT)" remote add origin https://github.com/NousResearch/hermes-agent; \
	  fi; \
	  echo "==> checking out hermes-agent @ $$sha"; \
	  git -C "$(HERMES_AGENT_CHECKOUT)" fetch --quiet --depth 1 origin "$$sha" && \
	  git -C "$(HERMES_AGENT_CHECKOUT)" checkout --quiet FETCH_HEAD
	cd hermes-plugin && \
	  ( test -d .venv || $(HERMES_PLUGIN_PYTHON) -m venv .venv ) && \
	  .venv/bin/pip install -q -e '.[dev]' && \
	  PYTHONPATH="$(HERMES_AGENT_CHECKOUT)" .venv/bin/python -m pytest -v

# Starts a real robot-notes server, built the way production does (see
# server/Dockerfile: `dart_frog build` + `dart build cli`), on a scratch
# port/data dir, points the hermes-plugin e2e suite at it via
# ROBOT_NOTES_E2E_BASE_URL/ROBOT_NOTES_E2E_API_KEY, then always stops the
# server and removes the scratch data dir again (trap on EXIT covers a failed
# test run too). Mirrors the `e2e` CI job in .github/workflows/ci.yml.
#
# This used to start the server with `dart_frog dev`, which spins up the
# framework's own VM supervisor directly and never runs Dart build hooks.
# package:sqlite3 (3.x) needs those hooks to bundle a native libsqlite3
# alongside the server; without them it falls back to whatever libsqlite3
# happens to already be resolvable in-process, which is true on most
# developer machines but not on a bare CI runner ("Couldn't resolve native
# function 'sqlite3_initialize' ... No available native assets"). Building
# the same way `docker build -f server/Dockerfile` does sidesteps that:
# `dart_frog build` renders the production server tree (server/build/), and
# `dart build cli` compiles it while running build hooks, producing a
# self-contained bundle (bin/server + lib/libsqlite3.so, resolved via the
# binary's relative rpath) of the same kind that ships in the image.
E2E_API_KEY ?= e2e-test-key-not-a-secret
E2E_DATA_DIR ?= $(CURDIR)/.e2e-data
E2E_PORT ?= 8098

test-hermes-plugin-e2e:
	@$(HERMES_PLUGIN_PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || \
	  { echo "error: $(HERMES_PLUGIN_PYTHON) is older than the Python >=3.10 hermes-plugin/pyproject.toml requires; install python3.10+ (e.g. via Homebrew)"; exit 1; }
	@command -v dart_frog >/dev/null 2>&1 || dart pub global activate dart_frog_cli
	cd hermes-plugin && \
	  ( test -d .venv || $(HERMES_PLUGIN_PYTHON) -m venv .venv ) && \
	  .venv/bin/pip install -q -e '.[dev]'
	rm -rf "$(E2E_DATA_DIR)" && mkdir -p "$(E2E_DATA_DIR)"
	rm -rf server/build
	cd server && dart_frog build
	# The generated entrypoint (server/build/bin/server.dart) hardcodes
	# `InternetAddress.anyIPv6`. GitHub-hosted Actions runners (and some
	# other hosts/containers) don't support IPv6 at all, so binding `::`
	# fails outright ("Address family not supported by protocol"). The old
	# `dart_frog dev --hostname 127.0.0.1` flag doesn't apply here --
	# `--hostname` is a dev-server-only option that never reaches this
	# generated file -- so patch the one line by hand to force IPv4
	# loopback instead, keeping the server bound to 127.0.0.1 as before.
	sed -i.bak 's/InternetAddress\.anyIPv6/InternetAddress.loopbackIPv4/' server/build/bin/server.dart && rm -f server/build/bin/server.dart.bak
	cd server/build && dart pub get && dart build cli -o out
	set -e; \
	  ROBOT_NOTES_API_KEY="$(E2E_API_KEY)" \
	  ROBOT_NOTES_DATA_DIR="$(E2E_DATA_DIR)" \
	  ROBOT_NOTES_PORT="$(E2E_PORT)" \
	  setsid server/build/out/bundle/bin/server \
	    > "$(CURDIR)/.e2e-server.log" 2>&1 < /dev/null & \
	SERVER_PID=$$!; \
	trap 'kill -- "-$$SERVER_PID" 2>/dev/null || kill "$$SERVER_PID" 2>/dev/null || true; rm -rf "$(E2E_DATA_DIR)" "$(CURDIR)/.e2e-server.log"' EXIT; \
	ready=0; \
	for i in $$(seq 1 60); do \
	  if curl -fsS "http://127.0.0.1:$(E2E_PORT)/healthz" >/dev/null 2>&1; then ready=1; break; fi; \
	  sleep 1; \
	done; \
	if [ "$$ready" != "1" ]; then \
	  echo "robot-notes server did not become healthy in time" >&2; \
	  cat "$(CURDIR)/.e2e-server.log" 2>/dev/null || true; \
	  exit 1; \
	fi; \
	cd hermes-plugin && \
	  ROBOT_NOTES_E2E_BASE_URL="http://127.0.0.1:$(E2E_PORT)" \
	  ROBOT_NOTES_E2E_API_KEY="$(E2E_API_KEY)" \
	  .venv/bin/python -m pytest -m e2e

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
