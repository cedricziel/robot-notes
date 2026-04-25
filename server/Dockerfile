# syntax=docker/dockerfile:1.7
#
# robot-notes server image.
#
# Build context: the repository root (the Dockerfile imports `shared/` via
# its workspace path dependency, so building from `server/` alone will not
# work). From the repo root run:
#
#   docker build -f server/Dockerfile -t robot-notes-server:dev .
#
# The image runs as a non-root user, exposes 8080, persists state under
# `/data` (a VOLUME), and ships a HEALTHCHECK that probes `/healthz`.

# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------
FROM dart:3.6.0-sdk@sha256:4598f4a37cda764808c931d9e1d77f8eb2aa283439702d7bc11205dd50846239 AS builder

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

USER 10001
EXPOSE 8080
VOLUME ["/data"]

ENV ROBOT_NOTES_DATA_DIR=/data \
    ROBOT_NOTES_PORT=8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O - http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/app/server"]
