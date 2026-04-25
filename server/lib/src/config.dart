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

    return Config(
      apiKey: apiKey,
      dataDir: dataDir,
      port: port,
      lockTtlSeconds: lockTtl,
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
