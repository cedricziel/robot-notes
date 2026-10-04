import 'dart:async';
import 'package:app/src/app_router.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/config/config_store.dart';
import 'package:flutter_test/flutter_test.dart';

const initial = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'secret',
  actor: 'tester',
);

class DelayedStore extends InMemoryConfigStore {
  final started = Completer<void>();
  final release = Completer<void>();
  bool fail = false;
  @override
  Future<void> write(AppConfig config) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    if (fail) throw StateError('storage unavailable');
    await super.write(config);
  }
}

void main() {
  test('logout waits for vault persistence and clears credentials', () async {
    final store = DelayedStore();
    final holder = ConfigHolder(store);
    addTearDown(holder.dispose);
    await Future<void>.delayed(Duration.zero);
    holder.set(initial);
    final selection = holder.selectVault('work');
    await store.started.future;
    final logout = holder.reset();
    store.release.complete();
    expect(await selection, isFalse);
    await logout;
    expect(holder.config, isNull);
    expect(await store.read(), isNull);
  });

  test(
    'failed persistence leaves selection unchanged and queue usable',
    () async {
      final store = DelayedStore()..fail = true;
      final holder = ConfigHolder(store);
      addTearDown(holder.dispose);
      await Future<void>.delayed(Duration.zero);
      holder.set(initial);
      store.release.complete();
      await expectLater(holder.selectVault('work'), throwsStateError);
      expect(holder.config, initial);
      await holder.reset();
      expect(await store.read(), isNull);
    },
  );

  test('rapid selections persist the last selection consistently', () async {
    final store = DelayedStore();
    final holder = ConfigHolder(store);
    addTearDown(holder.dispose);
    await Future<void>.delayed(Duration.zero);
    holder.set(initial);
    final first = holder.selectVault('work');
    final second = holder.selectVault('personal');
    store.release.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(holder.config?.vaultId, 'personal');
    expect(await store.read(), holder.config);
  });
}
