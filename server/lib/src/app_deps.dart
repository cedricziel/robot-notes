import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/storage.dart';

/// Long-lived dependencies shared across the whole server process.
///
/// Each request gets the same [Storage], [MetaIndex], and [LockManager]
/// instances threaded through the request context. Constructed once at boot
/// from the resolved [Config] and held by `app_deps_holder.dart`.
class AppDeps {
  /// Constructs a deps bundle wrapping the supplied collaborators directly.
  /// Tests use this to inject fakes; production callers should prefer
  /// [AppDeps.bootstrap].
  const AppDeps({
    required this.storage,
    required this.metaIndex,
    required this.lockManager,
    required this.clock,
  });

  /// Builds a deps bundle from the resolved [config], wiring up:
  /// - [Storage] rooted at `<dataDir>/content`
  /// - [MetaIndex] populated by scanning [Storage]
  /// - [LockManager] with TTL from `config.lockTtlSeconds`
  static Future<AppDeps> bootstrap(
    Config config, {
    Clock clock = const Clock(),
    Logger? logger,
  }) async {
    final log = logger ?? Logger('app_deps');
    final contentDir = Directory('${config.dataDir}/content');
    final storage = Storage(contentDir: contentDir, clock: clock);
    final metaIndex = MetaIndex();
    final loaded = await metaIndex.scan(storage);
    log.info('Bootstrapped MetaIndex with $loaded note(s)');
    final lockManager = LockManager(
      clock: clock,
      ttl: Duration(seconds: config.lockTtlSeconds),
    );
    return AppDeps(
      storage: storage,
      metaIndex: metaIndex,
      lockManager: lockManager,
      clock: clock,
    );
  }

  /// Canonical filesystem-backed note store.
  final Storage storage;

  /// In-memory listing index, derived from [storage].
  final MetaIndex metaIndex;

  /// Soft editor lock manager (process-local).
  final LockManager lockManager;

  /// Clock injected into every time-stamping component.
  final Clock clock;
}
