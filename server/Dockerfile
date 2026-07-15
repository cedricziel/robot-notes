# syntax=docker/dockerfile:1.7
#
# robot-notes server image.
#
# Build context: the repository root (the Dockerfile imports `shared/` via
# its workspace path dependency and `app/` for the Flutter web bundle, so
# building from `server/` alone will not work). From the repo root run:
#
#   docker build -f server/Dockerfile -t robot-notes-server:dev .
#
# The image is plug-and-play: it serves the Flutter web UI at `/` and the
# JSON/WebSocket API at the documented paths. It runs as a non-root user,
# exposes 8080, persists state under `/data` (a VOLUME), and ships a
# HEALTHCHECK that probes `/healthz`.
#
# Three build stages:
#   1. `web-builder`     — `flutter build web` produces the SPA bundle.
#   2. `server-builder`  — `dart_frog build` + `dart compile exe` produces
#      the AOT server binary.
#   3. runtime           — debian-slim, copies the bundle and the binary.

# ---------------------------------------------------------------------------
# Web builder — produces app/build/web/* (the Flutter SPA bundle).
# ---------------------------------------------------------------------------
# `--platform=$BUILDPLATFORM` pins this stage to the build host's native
# architecture. The bundle output is JS/HTML/WASM and architecture-
# independent, so we run Flutter once natively rather than emulating it
# under QEMU on each target arch.
#
# Tag + digest pinning. Re-resolve the digest when bumping the tag:
#
#   TOKEN=$(curl -s "https://ghcr.io/token?service=ghcr.io&\
#       scope=repository:cirruslabs/flutter:pull" | jq -r .token)
#   curl -sI -H "Authorization: Bearer $TOKEN" \
#     -H "Accept: application/vnd.oci.image.index.v1+json" \
#     https://ghcr.io/v2/cirruslabs/flutter/manifests/<TAG> \
#     | grep -i docker-content-digest
FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 AS web-builder

WORKDIR /workspace

# Copy the workspace pubspec and the two packages the Flutter app depends
# on (`app/` itself and `shared/`, which it imports via path). The server
# package isn't needed for `flutter build web`, so we strip it from the
# workspace declaration; otherwise `flutter pub get` errors with
# "Could not find a file named 'pubspec.yaml' in '/workspace/server'".
# Same `dev_dependencies`/`dart_pre_commit` strip the server-builder
# does — flutter doesn't need them either, and they pull packages we
# haven't copied (`dart_pre_commit`).
COPY pubspec.yaml ./
RUN sed -i '/^  - server$/d' pubspec.yaml \
 && sed -i '/^dev_dependencies:$/,$d' pubspec.yaml \
 && sed -i '/^dart_pre_commit:$/,$d' pubspec.yaml
COPY shared/ ./shared/
COPY app/ ./app/

# Resolve the workspace, then build the web bundle in release mode.
# `--no-tree-shake-icons` keeps icon glyphs reachable from runtime data
# (Flutter's tree-shaker can't follow Material Icons used by name).
RUN flutter pub get
RUN cd app && flutter build web --release --no-tree-shake-icons

# ---------------------------------------------------------------------------
# Web bundle — minimal stage that exposes ONLY the built SPA at the root.
# ---------------------------------------------------------------------------
# Two roles:
#   1. Local dev (`docker build` from the repo root): inherits from
#      `web-builder` above and gives the runtime stage a stable name to
#      copy from.
#   2. CI: a separate workflow job pre-builds the bundle once and the
#      arch-matrix builds override this stage via
#      `--build-context web-bundle=./prebuilt-web`. Because the runtime
#      copy uses `--from=web-bundle /`, the override only needs to
#      contain the bundle contents at its root — no path matching needed.
FROM scratch AS web-bundle
COPY --from=web-builder /workspace/app/build/web/ /

# ---------------------------------------------------------------------------
# Server builder
# ---------------------------------------------------------------------------
FROM dart:3.12.2-sdk@sha256:af2692895b25fae4188c84f1de84d16f191c1556db86d7b1862641a225c73d02 AS builder

ENV PATH="/root/.pub-cache/bin:${PATH}"

WORKDIR /workspace

# dart_frog_cli renders the production server tree (build/) we AOT-compile
# below. Pinning the major version keeps the renderer reproducible.
RUN dart pub global activate dart_frog_cli ^1.2.0

# Bring in the workspace root pubspec, then strip the `app` package and
# any `dev_dependencies` block so the builder doesn't pull the Flutter SDK.
COPY pubspec.yaml ./
RUN sed -i '/^  - app$/d' pubspec.yaml \
 && sed -i '/^dev_dependencies:$/,$d' pubspec.yaml \
 && sed -i '/^dart_pre_commit:$/,$d' pubspec.yaml

COPY shared/ ./shared/
COPY server/ ./server/

RUN dart pub get

WORKDIR /workspace/server
RUN dart_frog build

# build/ is a self-contained Dart package (shared is inlined under
# .dart_frog_path_dependencies/) so we can resolve and compile it without
# the surrounding workspace.
#
# `dart build cli` runs build hooks so package:sqlite3 (3.x) bundles
# libsqlite3 alongside the binary. Output layout:
#   /workspace/cli/bundle/bin/server
#   /workspace/cli/bundle/lib/libsqlite3.so
WORKDIR /workspace/server/build
RUN dart pub get
RUN dart build cli -o /workspace/cli

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

# OCI labels — CI passes BUILD_DATE/VCS_REF/VERSION as --build-arg values.
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION
LABEL org.opencontainers.image.source="https://github.com/cedricziel/robot-notes" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.title="robot-notes server" \
      org.opencontainers.image.description="Real-time markdown notes server (HTTP + WebSocket)."

# wget powers the HEALTHCHECK; ca-certificates is kept for any future
# outbound TLS. libsqlite3 is bundled with the binary by `dart build cli`
# (build hooks ship a libsqlite3.so under bundle/lib/), so no apt package
# is needed.
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates \
      wget \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 robotnotes \
 && useradd  --system --uid 10001 --gid 10001 --home-dir /app --no-create-home robotnotes \
 && mkdir -p /app /data \
 && chown -R 10001:10001 /app /data

WORKDIR /app
# bundle/ contains bin/server + lib/libsqlite3.so. Copy the whole bundle
# preserving relative layout so the binary's runtime DT_RPATH ($ORIGIN/../lib)
# resolves the bundled SQLite.
COPY --from=builder --chown=10001:10001 /workspace/cli/bundle /app
COPY --from=web-bundle --chown=10001:10001 / /app/web

USER 10001
EXPOSE 8080
VOLUME ["/data"]

ENV ROBOT_NOTES_DATA_DIR=/data \
    ROBOT_NOTES_PORT=8080 \
    ROBOT_NOTES_WEB_DIR=/app/web

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O - http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/app/bin/server"]
