import 'dart:async';
import 'dart:convert';

import 'package:app/src/api/api_client.dart';
import 'package:app/src/config/app_config.dart';
import 'package:app/src/notes/note_controller.dart';
import 'package:app/src/realtime/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

const _config = AppConfig(
  baseUrl: 'https://notes.example',
  apiKey: 'test-key',
  actor: 'cedric',
);

Map<String, Object?> _note({
  int version = 1,
  String title = 'Title',
  String content = 'Original',
}) => {
  'id': '01H',
  'version': version,
  'title': title,
  'content': content,
  'created_at': '2025-01-01T00:00:00.000Z',
  'updated_at': '2025-01-01T00:00:00.000Z',
};

http.Response _response(Map<String, Object?> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, Object?> _lock([String holder = 'cedric']) => {
  'holder': holder,
  'expires_at': '2025-01-01T00:01:00.000Z',
};

class _Backend {
  Map<String, Object?> note = _note();
  final saves = <http.Request>[];
  final saveResponses = <Completer<http.Response>>[];
  final patchResponses = <Completer<http.Response>>[];
  final autosaves = <Completer<void>>[];
  final heartbeats = <Completer<void>>[];
  http.Response? heartbeatResponse;
  final events = StreamController<RealtimeEvent>.broadcast(sync: true);
  Completer<http.Response>? acquisition;
  Completer<http.Response>? refetch;
  int releases = 0;

  late final api = RobotNotesClient(
    config: _config,
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/backlinks')) {
        return _response({'items': <Object?>[]});
      }
      if (request.url.path.endsWith('/lock')) {
        if (request.method == 'DELETE') {
          releases += 1;
          return http.Response('', 204);
        }
        if (request.method == 'PUT' && heartbeatResponse != null) {
          return heartbeatResponse!;
        }
        return acquisition?.future ?? _response(_lock());
      }
      if (request.method == 'PATCH') {
        final response = Completer<http.Response>();
        patchResponses.add(response);
        return response.future;
      }
      if (request.method == 'PUT') {
        saves.add(request);
        final response = Completer<http.Response>();
        saveResponses.add(response);
        return response.future;
      }
      return refetch?.future ?? _response(note);
    }),
  );

  NoteController controller() => NoteController(
    api: api,
    noteId: '01H',
    actor: 'cedric',
    events: events.stream,
    scheduler: (_) {
      final timer = Completer<void>();
      heartbeats.add(timer);
      return timer.future;
    },
    autosaveScheduler: (_) {
      final timer = Completer<void>();
      autosaves.add(timer);
      return timer.future;
    },
  );

  void loseLock() => events.add(
    RealtimeMessage(
      LockEvent(
        noteId: '01H',
        holder: 'alice',
        expiresAt: DateTime.utc(2025, 1, 1, 0, 1),
      ),
    ),
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _Backend backend;
  late NoteController controller;
  var disposed = false;

  setUp(() {
    disposed = false;
    backend = _Backend();
    controller = backend.controller();
  });
  tearDown(() async {
    if (!disposed) controller.dispose();
    await backend.events.close();
  });

  Future<void> editing() async {
    await controller.open();
    await controller.enterEditMode();
  }

  test('save acknowledgement retains newer title and Markdown edits', () async {
    await editing();
    controller.setEditContent('First draft');
    final saving = controller.save();
    await _settle();

    controller.setEditTitle('New title');
    controller.setEditContent('First draft\n\n- [x] More edits');
    expect(controller.value.isDirty, isTrue);
    backend.saveResponses.single.complete(
      _response(_note(version: 2, content: 'First draft')),
    );
    await saving;

    expect(controller.value.mode, NoteMode.editing);
    expect(controller.value.note?.version, 2);
    expect(controller.value.editTitle, 'New title');
    expect(controller.value.editContent, 'First draft\n\n- [x] More edits');
    expect(controller.value.isDirty, isTrue);
  });

  test('remaining draft autosaves using the acknowledged version', () async {
    await editing();
    controller.setEditContent('First');
    final saving = controller.save();
    await _settle();
    controller.setEditContent('Second');
    backend.autosaves.last.complete();
    await _settle();
    expect(backend.saves, hasLength(1));
    backend.saveResponses.single.complete(
      _response(_note(version: 2, content: 'First')),
    );
    await saving;

    expect(backend.autosaves.last.isCompleted, isFalse);
    backend.autosaves.last.complete();
    await _settle();
    expect(backend.saves, hasLength(2));
    expect(backend.saves.last.headers['if-match'], '2');
    expect(jsonDecode(backend.saves.last.body)['content'], 'Second');
    backend.saveResponses.last.complete(
      _response(_note(version: 3, content: 'Second')),
    );
    await _settle();
    expect(controller.value.isDirty, isFalse);
  });

  test(
    'an explicit save waits for the pending save and flushes newer edits',
    () async {
      await editing();
      controller.setEditContent('First');
      final first = controller.save();
      await _settle();
      controller.setEditContent('Final draft');
      final flush = controller.save();
      backend.saveResponses.single.complete(
        _response(_note(version: 2, content: 'First')),
      );
      await first;
      await _settle();

      expect(backend.saves, hasLength(2));
      expect(backend.saves.last.headers['if-match'], '2');
      backend.saveResponses.last.complete(
        _response(_note(version: 3, content: 'Final draft')),
      );
      await flush;
      expect(controller.value.editContent, 'Final draft');
      expect(controller.value.isDirty, isFalse);
    },
  );

  test(
    're-armed autosave waits for a property patch and uses its version',
    () async {
      await editing();
      controller.setEditContent('Submitted');
      final saving = controller.save();
      await _settle();
      controller.setEditContent('Retained');
      final patching = controller.patchProperty(set: {'status': 'Done'});
      backend.saveResponses.single.complete(
        _response(_note(version: 2, content: 'Submitted')),
      );
      await saving;
      await _settle();
      backend.autosaves.last.complete();
      await _settle();

      expect(backend.saves, hasLength(1));
      backend.patchResponses.single.complete(
        _response(_note(version: 3, content: 'Submitted')),
      );
      await patching;
      backend.autosaves.last.complete();
      await _settle();

      expect(backend.saves, hasLength(2));
      expect(backend.saves.last.headers['if-match'], '3');
      expect(jsonDecode(backend.saves.last.body)['content'], 'Retained');
      backend.saveResponses.last.complete(
        _response(_note(version: 4, content: 'Retained')),
      );
      await _settle();
      expect(controller.value.isDirty, isFalse);
    },
  );

  test(
    'save 423 retains a read-only draft and rejects further mutations',
    () async {
      await editing();
      controller.setEditTitle('Draft title');
      controller.setEditContent('Draft\n\n| untouched | table |');
      final saving = controller.save();
      await _settle();
      backend.saveResponses.single.complete(
        _response({'error': 'locked', 'lock': _lock('alice')}, 423),
      );
      await saving;
      controller.setEditTitle('Rejected');
      controller.setEditContent('Rejected');

      expect(controller.value.mode, NoteMode.viewing);
      expect(controller.value.editTitle, 'Draft title');
      expect(controller.value.editContent, 'Draft\n\n| untouched | table |');
      expect(controller.value.isDirty, isTrue);
      expect(controller.value.lock?.holder, 'alice');
    },
  );

  test(
    'lock loss during save stays read-only after its acknowledgement',
    () async {
      await editing();
      controller.setEditContent('Submitted');
      final saving = controller.save();
      await _settle();
      controller.setEditContent('Retained');
      backend.loseLock();
      backend.saveResponses.single.complete(
        _response(_note(version: 2, content: 'Submitted')),
      );
      await saving;

      expect(controller.value.mode, NoteMode.viewing);
      expect(controller.value.lock?.holder, 'alice');
      expect(controller.value.note?.version, 2);
      expect(controller.value.editContent, 'Retained');
      expect(controller.value.isDirty, isTrue);
    },
  );

  test(
    'heartbeat expiry retains the complete draft without allowing edits',
    () async {
      await editing();
      controller.setEditContent('Draft\n\n```dart\nopaque();\n```');
      backend.heartbeatResponse = _response({'error': 'not_found'}, 404);

      backend.heartbeats.single.complete();
      await _settle();
      controller.setEditContent('Rejected');

      expect(controller.value.mode, NoteMode.viewing);
      expect(controller.value.editContent, 'Draft\n\n```dart\nopaque();\n```');
      expect(controller.value.isDirty, isTrue);
      expect(controller.value.lock, isNull);
      expect(controller.value.lockedByOtherBanner, contains('expired'));
    },
  );

  test(
    'failed retry replaces the stale lock banner with the current holder',
    () async {
      await editing();
      controller.setEditContent('Retained draft');
      backend.loseLock();
      expect(controller.value.lockedByOtherBanner, contains('alice'));
      backend.acquisition = Completer<http.Response>()
        ..complete(_response({'error': 'locked', 'lock': _lock('bob')}, 423));

      await controller.enterEditMode();

      expect(controller.value.mode, NoteMode.viewing);
      expect(controller.value.lock?.holder, 'bob');
      expect(controller.value.lockedByOtherBanner, isNull);
      expect(controller.value.editContent, 'Retained draft');
      expect(controller.value.isDirty, isTrue);
    },
  );

  test(
    'retry restores a retained dirty draft when the server is unchanged',
    () async {
      await editing();
      controller.setEditContent('Retained draft');
      backend.loseLock();

      await controller.enterEditMode();

      expect(controller.value.mode, NoteMode.editing);
      expect(controller.value.editContent, 'Retained draft');
      expect(controller.value.isDirty, isTrue);
    },
  );

  test(
    'retry reconciles a dirty draft even after a read-only server refresh',
    () async {
      await editing();
      controller.setEditContent('Retained draft');
      backend.loseLock();
      backend.note = _note(version: 2, content: 'Remote draft');
      await controller.reload();

      await controller.enterEditMode();

      expect(controller.value.mode, NoteMode.conflict);
      expect(controller.value.editContent, 'Retained draft');
      expect(controller.value.conflictCurrent?.content, 'Remote draft');
      expect(controller.value.lock?.holder, 'cedric');
    },
  );

  test(
    'property response with remote body enters conflict while editing',
    () async {
      await editing();
      controller.setEditContent('Local draft');
      final patching = controller.patchProperty(set: {'status': 'Done'});
      await _settle();
      backend.note = _note(version: 2, content: 'Remote draft')
        ..['properties'] = {'status': 'Done'};
      backend.patchResponses.single.complete(_response(backend.note));
      await patching;

      expect(controller.value.mode, NoteMode.conflict);
      expect(controller.value.note?.version, 1);
      expect(controller.value.editContent, 'Local draft');
      expect(controller.value.conflictCurrent?.content, 'Remote draft');
      expect(controller.value.properties, {'status': 'Done'});
      backend.autosaves.last.complete();
      await _settle();
      expect(backend.saves, isEmpty);
    },
  );

  test(
    'property response with remote title enters conflict while editing',
    () async {
      await editing();
      controller.setEditTitle('Local draft');
      final patching = controller.patchProperty(set: {'status': 'Done'});
      await _settle();
      backend.note = _note(version: 2, title: 'Remote draft')
        ..['properties'] = {'status': 'Done'};
      backend.patchResponses.single.complete(_response(backend.note));
      await patching;

      expect(controller.value.mode, NoteMode.conflict);
      expect(controller.value.note?.version, 1);
      expect(controller.value.editTitle, 'Local draft');
      expect(controller.value.conflictCurrent?.title, 'Remote draft');
      expect(controller.value.properties, {'status': 'Done'});
      backend.autosaves.last.complete();
      await _settle();
      expect(backend.saves, isEmpty);
    },
  );

  test('property response with remote body enters conflict while editing an unchanged draft', () async {
    await editing();
    final patching = controller.patchProperty(set: {'status': 'Done'});
    await _settle();
    backend.note = _note(version: 2, content: 'Remote draft')
      ..['properties'] = {'status': 'Done'};
    backend.patchResponses.single.complete(_response(backend.note));
    await patching;

    expect(controller.value.mode, NoteMode.conflict);
    expect(controller.value.note?.version, 1);
    expect(controller.value.editContent, 'Original');
    expect(controller.value.conflictCurrent?.content, 'Remote draft');
    expect(controller.value.properties, {'status': 'Done'});
    expect(backend.autosaves, isEmpty);
    await _settle();
    expect(backend.saves, isEmpty);
  });

  test(
    'property response after lock loss preserves remote body conflicts',
    () async {
      await editing();
      controller.setEditContent('Local draft');
      final patching = controller.patchProperty(set: {'status': 'Done'});
      await _settle();
      backend.loseLock();
      backend.note = _note(version: 2, content: 'Remote draft');
      backend.patchResponses.single.complete(_response(backend.note));
      await patching;

      await controller.enterEditMode();

      expect(controller.value.mode, NoteMode.conflict);
      expect(controller.value.editContent, 'Local draft');
      expect(controller.value.conflictCurrent?.content, 'Remote draft');
      expect(backend.saves, isEmpty);
    },
  );

  test(
    'property response after lock loss preserves remote title conflicts',
    () async {
      await editing();
      controller.setEditTitle('Local draft');
      final patching = controller.patchProperty(set: {'status': 'Done'});
      await _settle();
      backend.loseLock();
      backend.note = _note(version: 2, title: 'Remote draft');
      backend.patchResponses.single.complete(_response(backend.note));
      await patching;

      await controller.enterEditMode();

      expect(controller.value.mode, NoteMode.conflict);
      expect(controller.value.editTitle, 'Local draft');
      expect(controller.value.conflictCurrent?.title, 'Remote draft');
      expect(backend.saves, isEmpty);
    },
  );

  test(
    'property-only response after lock loss advances the draft save version',
    () async {
      await editing();
      controller.setEditContent('Local draft');
      final patching = controller.patchProperty(set: {'status': 'Done'});
      await _settle();
      backend.loseLock();
      backend.note = _note(version: 2);
      backend.patchResponses.single.complete(_response(backend.note));
      await patching;

      await controller.enterEditMode();
      expect(controller.value.mode, NoteMode.editing);
      backend.autosaves.last.complete();
      await _settle();

      expect(backend.saves.single.headers['if-match'], '2');
      expect(jsonDecode(backend.saves.single.body)['content'], 'Local draft');
      backend.saveResponses.single.complete(
        _response(_note(version: 3, content: 'Local draft')),
      );
      await _settle();
      expect(controller.value.isDirty, isFalse);
    },
  );

  test('retry waits for a pending save before reacquiring the lock', () async {
    await editing();
    controller.setEditContent('Submitted');
    final saving = controller.save();
    await _settle();
    controller.setEditContent('Retained');
    backend.loseLock();
    final retrying = controller.enterEditMode();
    await _settle();

    expect(controller.value.mode, NoteMode.viewing);
    backend.note = _note(version: 2, content: 'Submitted');
    backend.saveResponses.single.complete(_response(backend.note));
    await saving;
    await retrying;

    expect(controller.value.mode, NoteMode.editing);
    expect(controller.value.note?.version, 2);
    expect(controller.value.editContent, 'Retained');
    expect(controller.value.isDirty, isTrue);
  });

  test(
    'lock takeover during acquisition refetch keeps the note read-only',
    () async {
      await controller.open();
      backend.refetch = Completer<http.Response>();
      final acquiring = controller.enterEditMode();
      await _settle();
      backend.loseLock();
      backend.refetch!.complete(_response(_note()));

      await acquiring;
      controller.setEditContent('Rejected');

      expect(controller.value.mode, NoteMode.viewing);
      expect(controller.value.lock?.holder, 'alice');
      expect(controller.value.editContent, isNull);
      expect(controller.value.lockedByOtherBanner, contains('alice'));
    },
  );

  test(
    'closing during acquisition releases the lock when it arrives',
    () async {
      await controller.open();
      backend.acquisition = Completer<http.Response>();
      final acquiring = controller.enterEditMode();
      await _settle();
      controller.dispose();
      disposed = true;
      backend.acquisition!.complete(_response(_lock()));

      await acquiring;

      expect(backend.releases, 1);
    },
  );

  test(
    'closing during acquisition refetch releases the acquired lock',
    () async {
      await controller.open();
      backend.refetch = Completer<http.Response>();
      final acquiring = controller.enterEditMode();
      await _settle();
      controller.dispose();
      disposed = true;
      backend.refetch!.complete(_response(_note()));

      await acquiring;

      expect(backend.releases, 1);
    },
  );
}
