import 'package:args/args.dart';
import 'package:meta/meta.dart';

/// Thrown by [Config.fromArgs] when the inputs cannot be resolved into a
/// valid runtime configuration.
class ConfigError implements Exception {
  /// Creates a config error wrapping a human-readable [message].
  ConfigError(this.message);

  /// Why the configuration is invalid. Suitable for printing to stderr.
  final String message;

  @override
  String toString() => 'ConfigError: $message';
}

/// OIDC login configuration: an external issuer this server delegates
/// human authentication to, per the `oidc-login` capability. Present only
/// when all three of `--oidc-issuer`, `--oidc-client-id`, and
/// `--oidc-client-secret` (or their `ROBOT_NOTES_OIDC_*` env equivalents)
/// are configured.
@immutable
class OidcConfig {
  /// Creates a fully-resolved OIDC configuration.
  const OidcConfig({
    required this.issuer,
    required this.clientId,
    required this.clientSecret,
  });

  /// The external OpenID Connect issuer's base URL (discovery is fetched
  /// from `<issuer>/.well-known/openid-configuration`).
  final String issuer;

  /// This server's client id, as registered with [issuer].
  final String clientId;

  /// This server's client secret, as registered with [issuer].
  final String clientSecret;
}

/// Resolved server runtime configuration. CLI flags take precedence over
/// the matching `ROBOT_NOTES_*` environment variables; both are evaluated
/// at startup and frozen for the life of the process.
@immutable
class Config {
  /// Builds a [Config] with every field already resolved.
  const Config({
    required this.apiKey,
    required this.dataDir,
    required this.port,
    required this.lockTtlSeconds,
    this.webDir,
    this.publicUrl,
    this.otlpEndpoint,
    this.otlpHeaders = const {},
    this.oidc,
  });

  /// Resolves a [Config] from CLI [args] and the supplied environment.
  ///
  /// Throws [ConfigError] when:
  /// - no API key is supplied via either source;
  /// - `--port` cannot be parsed as a positive integer;
  /// - `--lock-ttl-seconds` is below [minLockTtlSeconds].
  factory Config.fromArgs(
    List<String> args, {
    required Map<String, String> env,
  }) {
    final ArgResults parsed;
    try {
      parsed = buildParser().parse(args);
    } on FormatException catch (e) {
      throw ConfigError(e.message);
    }

    final apiKey = _coalesce(
      parsed['api-key'] as String?,
      env['ROBOT_NOTES_API_KEY'],
    );
    if (apiKey == null || apiKey.isEmpty) {
      throw ConfigError(
        'No API key configured. Pass --api-key <key> or set the '
        'ROBOT_NOTES_API_KEY environment variable.',
      );
    }

    final dataDir = _coalesce(
          parsed['data-dir'] as String?,
          env['ROBOT_NOTES_DATA_DIR'],
        ) ??
        defaultDataDir;

    final port = _parseInt(
      _coalesce(parsed['port'] as String?, env['ROBOT_NOTES_PORT']),
      field: '--port',
      fallback: defaultPort,
    );
    if (port <= 0 || port > 65535) {
      throw ConfigError('--port must be between 1 and 65535 (got $port).');
    }

    final lockTtl = _parseInt(
      _coalesce(
        parsed['lock-ttl-seconds'] as String?,
        env['ROBOT_NOTES_LOCK_TTL_SECONDS'],
      ),
      field: '--lock-ttl-seconds',
      fallback: defaultLockTtlSeconds,
    );
    if (lockTtl < minLockTtlSeconds) {
      throw ConfigError(
        '--lock-ttl-seconds must be >= $minLockTtlSeconds (got $lockTtl).',
      );
    }

    final webDir = _coalesce(
      parsed['web-dir'] as String?,
      env['ROBOT_NOTES_WEB_DIR'],
    );

    final publicUrl = _resolvePublicUrl(
      _coalesce(
        parsed['public-url'] as String?,
        env['ROBOT_NOTES_PUBLIC_URL'],
      ),
    );

    final otlpEndpoint = _resolveOtlpEndpoint(
      _coalesce(
        parsed['otel-endpoint'] as String?,
        env['ROBOT_NOTES_OTEL_ENDPOINT'],
      ),
    );

    final otlpHeaders = _parseOtlpHeaders(
      _coalesce(
        parsed['otel-headers'] as String?,
        env['ROBOT_NOTES_OTEL_HEADERS'],
      ),
    );

    final oidc = _resolveOidc(parsed, env);

    return Config(
      apiKey: apiKey,
      dataDir: dataDir,
      port: port,
      lockTtlSeconds: lockTtl,
      webDir: webDir,
      publicUrl: publicUrl,
      otlpEndpoint: otlpEndpoint,
      otlpHeaders: otlpHeaders,
      oidc: oidc,
    );
  }

  /// Default note/storage root when neither flag nor env supplies one.
  static const String defaultDataDir = './data';

  /// Default TCP port the HTTP server binds to.
  static const int defaultPort = 8080;

  /// Default editor-lock TTL in seconds.
  static const int defaultLockTtlSeconds = 60;

  /// Floor for `--lock-ttl-seconds`; values below this are rejected.
  static const int minLockTtlSeconds = 5;

  /// Bearer key required on every HTTP request and the WebSocket auth frame.
  final String apiKey;

  /// Directory containing notes (`content/`), search index, and invites.
  final String dataDir;

  /// TCP port the server listens on.
  final int port;

  /// TTL applied to every soft editor lock acquire/heartbeat, in seconds.
  final int lockTtlSeconds;

  /// Optional directory containing the Flutter web bundle. When set, the
  /// server mounts the bundle at the root and serves `index.html`/assets
  /// without the bearer-key requirement; the bundle itself never contains
  /// secrets. `null` disables static serving.
  final String? webDir;

  /// Optional absolute origin (scheme, host, optional port; no path, query,
  /// or fragment; no trailing slash) pinning the base URL used in OAuth
  /// metadata, redirects, and invite URLs. `null` means the base is derived
  /// per request from `X-Forwarded-Proto`/the request scheme and `Host`.
  final String? publicUrl;

  /// Base endpoint for OTLP/HTTP telemetry export. `null` disables export
  /// entirely (the default): no OTel dependency is configured, so this is
  /// safe to leave unset. `/v1/logs` is appended by the exporter.
  final Uri? otlpEndpoint;

  /// Extra headers (e.g. an auth token) sent with every OTLP export request.
  /// Empty by default.
  final Map<String, String> otlpHeaders;

  /// OIDC login configuration, or `null` when OIDC login is disabled (the
  /// default — every request behaves exactly as without this capability).
  final OidcConfig? oidc;

  /// Builds an [ArgParser] mirroring the documented CLI surface.
  static ArgParser buildParser() => ArgParser()
    ..addOption('api-key', help: 'Bearer API key required on every request.')
    ..addOption(
      'data-dir',
      help: 'Directory where notes, search index, and invites are stored.',
    )
    ..addOption('port', help: 'TCP port to listen on.')
    ..addOption(
      'lock-ttl-seconds',
      help: 'Soft editor lock TTL in seconds (min 5).',
    )
    ..addOption(
      'web-dir',
      help: 'Path to the Flutter web bundle. When set, the server serves '
          'the bundle at /. Leave empty to run as an API-only server.',
    )
    ..addOption(
      'public-url',
      help: 'Absolute http(s) origin (no path, query, or fragment) used as '
          'the public base URL for OAuth metadata and invite links behind '
          'a reverse proxy.',
    )
    ..addOption(
      'otel-endpoint',
      help: 'Base OTLP/HTTP endpoint telemetry is exported to. Unset '
          'disables telemetry export.',
    )
    ..addOption(
      'otel-headers',
      help: 'Comma-separated key=value headers sent with every OTLP '
          'export request (e.g. an auth token).',
    )
    ..addOption(
      'oidc-issuer',
      help: 'External OIDC issuer base URL. Requires --oidc-client-id and '
          '--oidc-client-secret to also be set.',
    )
    ..addOption(
      'oidc-client-id',
      help: "This server's client id as registered with --oidc-issuer.",
    )
    ..addOption(
      'oidc-client-secret',
      help: "This server's client secret as registered with "
          '--oidc-issuer.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print usage.');

  /// Resolves a [Config] or terminates the process. Suitable for the server
  /// entrypoint. The `exit` and `printErr` callbacks are injectable to keep
  /// the call testable.
  // ignore: prefer_constructors_over_static_methods
  static Config loadOrExit(
    List<String> args, {
    required Map<String, String> env,
    required void Function(int code) exit,
    required void Function(String line) printErr,
  }) {
    try {
      return Config.fromArgs(args, env: env);
    } on ConfigError catch (e) {
      printErr(e.message);
      printErr('');
      printErr('Usage: dart_frog dev [-- --api-key <key>] [--data-dir <path>]');
      printErr('       [--port <int>] [--lock-ttl-seconds <int>]');
      printErr('       [--web-dir <path>] [--public-url <origin>]');
      printErr('       [--otel-endpoint <url>] [--otel-headers <k=v,...>]');
      exit(64); // EX_USAGE
      // exit() should not return; rethrow defensively if a test stub does.
      rethrow;
    }
  }

  static String? _coalesce(String? a, String? b) {
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    return null;
  }

  /// Validates a raw `--public-url` / `ROBOT_NOTES_PUBLIC_URL` value and
  /// normalizes it to an origin with no trailing slash. Returns `null` when
  /// [raw] is `null`. Throws [ConfigError] when the value is not an
  /// absolute `http`/`https` URL with an empty path (or exactly `/`), no
  /// query, no fragment, and no userinfo.
  static String? _resolvePublicUrl(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    final valid = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery &&
        !uri.hasFragment;
    if (!valid) {
      throw ConfigError(
        'Invalid --public-url / ROBOT_NOTES_PUBLIC_URL value "$raw": must '
        'be an absolute http or https URL with no userinfo, path, query, '
        'or fragment.',
      );
    }
    return uri.replace(path: '').toString();
  }

  /// Validates a raw `--otel-endpoint` / `ROBOT_NOTES_OTEL_ENDPOINT` value.
  /// Returns `null` when [raw] is `null`. Throws [ConfigError] when the
  /// value is not an absolute `http`/`https` URL with a non-empty host.
  static Uri? _resolveOtlpEndpoint(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    final valid = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!valid) {
      throw ConfigError(
        'Invalid --otel-endpoint / ROBOT_NOTES_OTEL_ENDPOINT value "$raw": '
        'must be an absolute http or https URL with a host.',
      );
    }
    return uri;
  }

  /// Parses `--otel-headers` / `ROBOT_NOTES_OTEL_HEADERS` as comma-separated
  /// `key=value` pairs. Returns an empty map when [raw] is `null`. Throws
  /// [ConfigError] when an entry has no `=`.
  static Map<String, String> _parseOtlpHeaders(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    final headers = <String, String>{};
    for (final entry in raw.split(',')) {
      final separator = entry.indexOf('=');
      if (separator <= 0) {
        throw ConfigError(
          'Invalid --otel-headers / ROBOT_NOTES_OTEL_HEADERS entry '
          '"$entry": expected "key=value".',
        );
      }
      headers[entry.substring(0, separator)] = entry.substring(separator + 1);
    }
    return headers;
  }

  /// Resolves [OidcConfig] from the three `--oidc-*` flags / `ROBOT_NOTES_
  /// OIDC_*` env vars (CLI wins per-setting). Returns `null` when none of
  /// the three are set. Throws [ConfigError] naming whichever setting(s)
  /// are missing when one or two (but not all three) are set.
  static OidcConfig? _resolveOidc(
    ArgResults parsed,
    Map<String, String> env,
  ) {
    final issuer = _coalesce(
      parsed['oidc-issuer'] as String?,
      env['ROBOT_NOTES_OIDC_ISSUER'],
    );
    final clientId = _coalesce(
      parsed['oidc-client-id'] as String?,
      env['ROBOT_NOTES_OIDC_CLIENT_ID'],
    );
    final clientSecret = _coalesce(
      parsed['oidc-client-secret'] as String?,
      env['ROBOT_NOTES_OIDC_CLIENT_SECRET'],
    );

    if (issuer == null && clientId == null && clientSecret == null) {
      return null;
    }

    final missing = <String>[
      if (issuer == null) '--oidc-issuer / ROBOT_NOTES_OIDC_ISSUER',
      if (clientId == null) '--oidc-client-id / ROBOT_NOTES_OIDC_CLIENT_ID',
      if (clientSecret == null)
        '--oidc-client-secret / ROBOT_NOTES_OIDC_CLIENT_SECRET',
    ];
    if (missing.isNotEmpty) {
      throw ConfigError(
        'OIDC login is partially configured; also set: '
        '${missing.join(', ')}.',
      );
    }

    return OidcConfig(
      issuer: issuer!,
      clientId: clientId!,
      clientSecret: clientSecret!,
    );
  }

  static int _parseInt(
    String? raw, {
    required String field,
    required int fallback,
  }) {
    if (raw == null) return fallback;
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw ConfigError('$field must be an integer (got "$raw").');
    }
    return parsed;
  }
}
