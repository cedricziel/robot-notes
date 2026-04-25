import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../config/app_config.dart';
import '../config/config_store.dart';

/// Why a setup attempt failed. Drives the UI message and is also useful in
/// tests so we can assert the *category* of failure rather than coupling to
/// the exact wording.
enum SetupFailureReason { unauthorized, network, server }

/// Sealed state machine for the setup screen.
///
/// `idle` → `submitting` → (`success` | `failed`) and back to `submitting`
/// on retry. The screen is a pure function of this state.
sealed class SetupState {
  const SetupState();
}

class SetupIdle extends SetupState {
  const SetupIdle();
}

class SetupSubmitting extends SetupState {
  const SetupSubmitting();
}

class SetupFailed extends SetupState {
  const SetupFailed(this.reason, this.message);
  final SetupFailureReason reason;
  final String message;
}

class SetupSuccess extends SetupState {
  const SetupSuccess(this.config);
  final AppConfig config;
}

/// Drives the first-run validation flow.
///
/// Validation hits two endpoints in sequence:
///   1. `GET /healthz` (no auth) — proves the URL is reachable and points at
///      a robot-notes server.
///   2. `GET /notes?limit=1` (with `Authorization` + `X-Actor`) — proves the
///      key is accepted.
///
/// Only after both succeed do we persist via [ConfigStore]. The controller
/// builds (and disposes) one [http.Client] per submission so a failed attempt
/// can't keep a stale connection around.
///
/// **Logging contract:** the api key MUST NEVER appear in any log line.
/// We log only the base url and outcome. Tests in
/// `setup_controller_test.dart` assert this contract by capturing the log
/// stream end-to-end.
class SetupController extends ValueNotifier<SetupState> {
  SetupController({
    required ConfigStore store,
    http.Client Function()? clientFactory,
    Logger? logger,
    Duration timeout = const Duration(seconds: 10),
  })  : _store = store,
        _clientFactory = clientFactory ?? http.Client.new,
        _log = logger ?? Logger('robot_notes.setup'),
        _timeout = timeout,
        super(const SetupIdle());

  final ConfigStore _store;
  final http.Client Function() _clientFactory;
  final Logger _log;
  final Duration _timeout;

  Future<void> submit({
    required String baseUrl,
    required String apiKey,
    required String actor,
  }) async {
    final draft = AppConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      actor: actor,
    ).normalized();

    value = const SetupSubmitting();
    _log.info('setup.submit start baseUrl=${draft.baseUrl}');

    final client = _clientFactory();
    try {
      final healthUri = Uri.parse('${draft.baseUrl}/healthz');
      try {
        final res = await client.get(healthUri).timeout(_timeout);
        if (res.statusCode != 200) {
          _log.warning('setup.healthz status=${res.statusCode}');
          value = SetupFailed(
            SetupFailureReason.server,
            'Server responded ${res.statusCode} on /healthz. '
            'Is this a robot-notes server?',
          );
          return;
        }
      } on TimeoutException {
        _log.warning('setup.healthz timeout');
        value = const SetupFailed(
          SetupFailureReason.network,
          'Server did not respond. Check the URL and your network.',
        );
        return;
      } on SocketException {
        _log.warning('setup.healthz socket-error');
        value = const SetupFailed(
          SetupFailureReason.network,
          'Could not reach server. Check the URL and your network.',
        );
        return;
      } on http.ClientException {
        _log.warning('setup.healthz client-error');
        value = const SetupFailed(
          SetupFailureReason.network,
          'Could not reach server. Check the URL and your network.',
        );
        return;
      }

      final notesUri = Uri.parse('${draft.baseUrl}/notes?limit=1');
      final http.Response notes;
      try {
        notes = await client.get(
          notesUri,
          headers: {
            'Authorization': 'Bearer ${draft.apiKey}',
            'X-Actor': draft.actor,
          },
        ).timeout(_timeout);
      } on TimeoutException {
        _log.warning('setup.notes timeout');
        value = const SetupFailed(
          SetupFailureReason.network,
          'Server did not respond. Check the URL and your network.',
        );
        return;
      } on SocketException {
        _log.warning('setup.notes socket-error');
        value = const SetupFailed(
          SetupFailureReason.network,
          'Could not reach server. Check the URL and your network.',
        );
        return;
      } on http.ClientException {
        _log.warning('setup.notes client-error');
        value = const SetupFailed(
          SetupFailureReason.network,
          'Could not reach server. Check the URL and your network.',
        );
        return;
      }

      if (notes.statusCode == 401) {
        _log.warning('setup.notes status=401');
        value = const SetupFailed(
          SetupFailureReason.unauthorized,
          'API key was rejected by the server.',
        );
        return;
      }
      if (notes.statusCode != 200) {
        _log.warning('setup.notes status=${notes.statusCode}');
        value = SetupFailed(
          SetupFailureReason.server,
          'Server responded ${notes.statusCode} on /notes.',
        );
        return;
      }

      await _store.write(draft);
      _log.info(
        'setup.submit ok baseUrl=${draft.baseUrl} actor=${draft.actor}',
      );
      value = SetupSuccess(draft);
    } finally {
      client.close();
    }
  }
}
