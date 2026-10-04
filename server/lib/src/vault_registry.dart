import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server/src/app_deps.dart';
import 'package:server/src/config.dart';
import 'package:ulid/ulid.dart';

/// Persistent vault catalog. Existing content belongs to the default vault.
class VaultRegistry {
  /// Creates a catalog for the server data directory.
  VaultRegistry({required this.root, required this.config});

  /// Services backing the existing default vault.
  final AppDeps root;

  /// Configuration inherited by additional vaults.
  final Config config;
  final Map<String, Future<AppDeps>> _opened = {};
  File get _catalog => File('${config.dataDir}/vaults.json');
  final Map<String, String> _names = {'default': 'Default'};

  /// Restores the catalog at server startup.
  Future<void> load() async {
    if (await _catalog.exists()) {
      _names.addAll(
        Map<String, String>.from(
          jsonDecode(await _catalog.readAsString()) as Map,
        ),
      );
    }
  }

  /// Returns the stable IDs and display names of known vaults.
  List<Map<String, String>> list() => [
        for (final entry in _names.entries)
          {'id': entry.key, 'name': entry.value},
      ];

  /// Whether an ID exists in this catalog.
  bool contains(String id) => _names.containsKey(id);

  Future<void> _save() async {
    await _catalog.parent.create(recursive: true);
    final tmp = File('${_catalog.path}.tmp');
    await tmp.writeAsString(jsonEncode(_names), flush: true);
    await tmp.rename(_catalog.path);
  }

  // Serialize catalog changes so concurrent creates cannot lose entries.
  Future<void> _pending = Future<void>.value();
  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Creates a vault with a generated stable ID.
  Future<Map<String, String>> create(String name) => _mutate(() async {
        final id = Ulid().toString().toLowerCase();
        _names[id] = name;
        try {
          await _save();
        } on Object {
          _names.remove(id);
          rethrow;
        }
        return {'id': id, 'name': name};
      });

  /// Changes a display name without moving any content.
  Future<void> rename(String id, String name) => _mutate(() async {
        if (!contains(id)) throw StateError('Unknown vault');
        final previous = _names[id]!;
        _names[id] = name;
        try {
          await _save();
        } on Object {
          _names[id] = previous;
          rethrow;
        }
      });

  /// Lazily opens independent services for the selected vault.
  Future<AppDeps> open(String id) {
    if (!contains(id)) throw StateError('Unknown vault');
    if (id == 'default') return Future.value(root);
    return _opened.putIfAbsent(id, () async {
      try {
        return await AppDeps.bootstrap(
          Config(
            apiKey: config.apiKey,
            dataDir: '${config.dataDir}/vaults/$id',
            port: config.port,
            lockTtlSeconds: config.lockTtlSeconds,
            maxUploadSizeBytes: config.maxUploadSizeBytes,
            embeddingProvider: config.embeddingProvider,
            ollamaBaseUrl: config.ollamaBaseUrl,
            ollamaEmbeddingModel: config.ollamaEmbeddingModel,
          ),
          clock: root.clock,
          initializeVaults: false,
        );
      } on Object {
        unawaited(_opened.remove(id));
        rethrow;
      }
    });
  }

  /// Releases all opened vault resources, excluding the default vault.
  Future<void> close() async {
    for (final deps in _opened.values) {
      await (await deps).close();
    }
    _opened.clear();
  }
}
