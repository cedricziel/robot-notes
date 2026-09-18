/// Single source of truth for the robot-notes release version.
///
/// release-please rewrites the version literal on every release via the
/// `x-release-please-version` marker; do not edit it by hand.
const String robotNotesVersion = '0.2.13'; // x-release-please-version

/// The `service.namespace` OTel resource attribute shared by every
/// robot-notes process (server, app, probe) — one constant so the server
/// and app can never drift on the value that ties their telemetry
/// together into one system in the backend.
const String otelServiceNamespace = 'robot-notes';
