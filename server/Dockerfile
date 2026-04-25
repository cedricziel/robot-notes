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
FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:3.27.0@sha256:3aa235f10b9700466ee5fc92ece03e867c336168ead60ef7449480a38c6cd92e AS web-builder

WORKDIR /workspace

# Copy the workspace pubspec and the two packages the Flutter app depends
# on (`app/` itself and `shared/`, which it imports via path). The server
# package isn't needed for `flutter build web`.
COPY pubspec.yaml ./
COPY shared/ ./shared/
COPY app/ ./app/

# Resolve the workspace, then build the web bundle in release mode.
# `--no-tree-shake-icons` keeps icon glyphs reachable from runtime data
# (Flutter's tree-shaker can't follow Material Icons used by name).
RUN flutter pub get
RUN cd app && flutter build web --release --no-tree-shake-icons

# ---------------------------------------------------------------------------
# Server builder
# ---------------------------------------------------------------------------
FROM dart:3.11.0-sdk@sha256:193a4d037dcef48b56f2a3544f053f4ef3b5e9865953f8f5ff2a284554da567a AS builder

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
WORKDIR /workspace/server/build
RUN dart pub get
RUN dart compile exe bin/server.dart -o /workspace/server.exe

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252

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

# wget powers the HEALTHCHECK; libsqlite3-0 is dlopen()ed by package:sqlite3
# at runtime; ca-certificates is kept for any future outbound TLS.
RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates \
      libsqlite3-0 \
      wget \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 robotnotes \
 && useradd  --system --uid 10001 --gid 10001 --home-dir /app --no-create-home robotnotes \
 && mkdir -p /app /data \
 && chown -R 10001:10001 /app /data

WORKDIR /app
COPY --from=builder --chown=10001:10001 /workspace/server.exe /app/server
COPY --from=web-builder --chown=10001:10001 /workspace/app/build/web /app/web

USER 10001
EXPOSE 8080
VOLUME ["/data"]

ENV ROBOT_NOTES_DATA_DIR=/data \
    ROBOT_NOTES_PORT=8080 \
    ROBOT_NOTES_WEB_DIR=/app/web

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O - http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/app/server"]
