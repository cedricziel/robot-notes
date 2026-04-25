import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:server/src/clock.dart';
import 'package:server/src/config.dart';
import 'package:server/src/invite_store.dart';
import 'package:server/src/lock_manager.dart';
import 'package:server/src/meta_index.dart';
import 'package:server/src/search_index.dart';
import 'package:server/src/storage.dart';
import 'package:server/src/ws/broadcaster.dart';
import 'package:server/src/ws/presence.dart';
import 'package:shared/shared.dart';

/// Long-lived dependencies shared across the whole server process.
///
/// Each request gets the same [Storage], [MetaIndex], [LockManager],
/// [Broadcaster], and [PresenceTracker] instances threaded through the
/// request context. Constructed once at boot from the resolved [Config] and
/// held by `app_deps_holder.dart`.
class AppDeps {
  /// Constructs a deps bundle wrapping the supplied collaborators directly.
  /// Tests use this to inject fakes; production callers should prefer
  /// [AppDeps.bootstrap].
  AppDeps({
    required this.storage,
    required this.metaIndex,
    required this.searchIndex,
    required this.inviteStore,
    required this.lockManager,
    required this.broadcaster,
    required this.presence,
    required this.clock,
  }) {
    _lockSub = lockManager.transitions.listen(broadcaster.emitLock);
  }

  /// Builds a deps bundle from the resolved [config], wiring up:
  /// - [Storage] rooted at `<dataDir>/content`
  /// - [MetaIndex] populated by scanning [Storage]
  /// - [LockManager] with TTL from `config.lockTtlSeconds`
  /// - [Broadcaster] subscribed to lock-manager transitions
  /// - [PresenceTracker] for per-note viewer rosters
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
    final searchIndex = await SearchIndex.open(
      dbFile: File('${config.dataDir}/search.db'),
      storage: storage,
      logger: Logger('search_index'),
    );
    final inviteStore = InviteStore(
      inviteDir: Directory('${config.dataDir}/invites'),
      clock: clock,
    );
    return AppDeps(
      storage: storage,
      metaIndex: metaIndex,
      searchIndex: searchIndex,
      inviteStore: inviteStore,
      lockManager: lockManager,
      broadcaster: Broadcaster(),
      presence: PresenceTracker(),
      clock: clock,
    );
  }

  /// Canonical filesystem-backed note store.
  final Storage storage;

  /// In-memory listing index, derived from [storage].
  final MetaIndex metaIndex;

  /// FTS5-backed full-text search index, derived from [storage].
  final SearchIndex searchIndex;

  /// Filesystem-backed agent-onboarding invite store.
  final InviteStore inviteStore;

  /// Soft editor lock manager (process-local).
  final LockManager lockManager;

  /// Routing layer that fans LockEvents, ChangedEvents, and PresenceEvents
  /// out to subscribed WebSocket connections.
  final Broadcaster broadcaster;

  /// Per-note viewer roster used by the WS layer.
  final PresenceTracker presence;

  /// Clock injected into every time-stamping component.
  final Clock clock;

  StreamSubscription<LockEvent>? _lockSub;

  /// Releases long-lived resources. Tests use this between scenarios; the
  /// production server keeps a single [AppDeps] for its full lifetime.
  Future<void> close() async {
    await _lockSub?.cancel();
    _lockSub = null;
    await broadcaster.close();
    await lockManager.close();
    searchIndex.close();
  }
}
