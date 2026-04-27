import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'src/api/api_client.dart';
import 'src/api/api_exceptions.dart';
import 'src/config/app_config.dart';
import 'src/config/config_store.dart';
import 'src/notes/note_controller.dart';
import 'src/notes/note_screen.dart';
import 'src/notes/notes_list_controller.dart';
import 'src/notes/notes_list_screen.dart';
import 'src/realtime/ws_client.dart';
import 'src/search/search_controller.dart';
import 'src/search/search_screen.dart';
import 'src/setup/setup_controller.dart';
import 'src/setup/setup_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: RobotNotesApp()));
}

/// Builds the placeholder title for a freshly-created note, prefixed
/// with the calendar date so the list stays roughly chronological even
/// before the user renames it. Format: `YYYY-MM-DD Untitled`.
///
/// Pure / time-injectable so widget tests can pin a deterministic value.
String blankNoteTitle(DateTime now) {
  final y = now.year.toString().padLeft(4, '0');
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return '$y-$m-$d Untitled';
}

/// Creates a fresh note with the date-prefixed placeholder title and
/// empty content. The server rejects empty titles (`POST /notes`
/// requires a non-empty string), so the client always sends a stand-in;
/// the user renames it inline once the editor opens.
///
/// Extracted so widget tests can exercise the same call the FAB does
/// without having to mount the full app shell.
Future<Note> createBlankNote(RobotNotesClient api, {DateTime? now}) {
  final title = blankNoteTitle(now ?? DateTime.now());
  return api.createNote(title: title, content: '');
}

/// Root widget for the robot-notes Flutter client.
class RobotNotesApp extends StatelessWidget {
  const RobotNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'robot-notes',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const _Bootstrap(),
    );
  }
}

/// Reads the persisted [AppConfig] (if any) and routes to either the
/// first-run [SetupScreen] or the main [_AppShell]. A single instance of
/// [SecureConfigStore] is owned here and threaded down both branches so
/// the setup flow and a later "reset" both write through the same store.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final ConfigStore _store = SecureConfigStore();
  late Future<AppConfig?> _initial;

  @override
  void initState() {
    super.initState();
    _initial = _store.read();
  }

  void _onConfigured(AppConfig config) {
    setState(() {
      _initial = Future<AppConfig?>.value(config);
    });
  }

  Future<void> _reset() async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _initial = Future<AppConfig?>.value(null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppConfig?>(
      future: _initial,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _Splash();
        }
        final config = snapshot.data;
        if (config == null) {
          return _SetupRoute(store: _store, onConfigured: _onConfigured);
        }
        return _AppShell(
          // Recreate the shell whenever the config changes so the
          // RobotNotesClient and WS client see the new credentials.
          key: ValueKey<String>('${config.baseUrl}|${config.actor}'),
          config: config,
          onReset: _reset,
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

/// Owns the [SetupController] for as long as the setup screen is on screen.
/// The controller persists the validated [AppConfig] itself; this widget
/// just relays the [SetupSuccess] up to [_BootstrapState].
class _SetupRoute extends StatefulWidget {
  const _SetupRoute({required this.store, required this.onConfigured});

  final ConfigStore store;
  final ValueChanged<AppConfig> onConfigured;

  @override
  State<_SetupRoute> createState() => _SetupRouteState();
}

class _SetupRouteState extends State<_SetupRoute> {
  late final SetupController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SetupController(store: widget.store);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SetupScreen(
      controller: _controller,
      onConfigured: widget.onConfigured,
    );
  }
}

/// The main authenticated shell. Owns the singleton [RobotNotesClient] and
/// [RobotNotesWsClient] for the session, plus the cross-screen
/// [NotesListController] so the list survives navigation pushes.
class _AppShell extends StatefulWidget {
  const _AppShell({
    required this.config,
    required this.onReset,
    super.key,
  });

  final AppConfig config;
  final VoidCallback onReset;

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  late final RobotNotesClient _api;
  late final RobotNotesWsClient _ws;
  late final NotesListController _list;

  @override
  void initState() {
    super.initState();
    _api = RobotNotesClient(config: widget.config);
    _ws = RobotNotesWsClient(config: widget.config);
    _list = NotesListController(api: _api, events: _ws.events);
    unawaited(_ws.start());
    // Wildcard subscription keeps the list in sync with everyone's writes.
    _ws.subscribe('*');
  }

  @override
  void dispose() {
    _list.dispose();
    unawaited(_ws.dispose());
    _api.close();
    super.dispose();
  }

  Future<void> _openNote(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _NoteRoute(
          api: _api,
          ws: _ws,
          actor: widget.config.actor,
          noteId: id,
        ),
      ),
    );
  }

  Future<void> _openSearch() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _SearchRoute(api: _api),
      ),
    );
    if (id != null && mounted) {
      await _openNote(id);
    }
  }

  Future<void> _createNote() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final note = await createBlankNote(_api);
      if (!mounted) return;
      await _openNote(note.id);
    } on ApiException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not create note: ${e.message}')),
      );
    }
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect from server?'),
        content: const Text(
          'This clears the saved server URL, API key, and display name. '
          "You'll be asked to reconnect next time.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      widget.onReset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotesListScreen(
      controller: _list,
      onNoteTap: _openNote,
      onCreate: _createNote,
      appBarActions: [
        IconButton(
          key: const Key('shell.search'),
          tooltip: 'Search',
          icon: const Icon(Icons.search),
          onPressed: _openSearch,
        ),
        IconButton(
          key: const Key('shell.reset'),
          tooltip: 'Disconnect',
          icon: const Icon(Icons.logout),
          onPressed: _confirmReset,
        ),
      ],
    );
  }
}

/// Per-note route. The controller's lifetime is tied to this widget so
/// pushing/popping a note cleanly acquires/releases its WS subscription
/// and any held lock.
class _NoteRoute extends StatefulWidget {
  const _NoteRoute({
    required this.api,
    required this.ws,
    required this.actor,
    required this.noteId,
  });

  final RobotNotesClient api;
  final RobotNotesWsClient ws;
  final String actor;
  final String noteId;

  @override
  State<_NoteRoute> createState() => _NoteRouteState();
}

class _NoteRouteState extends State<_NoteRoute> {
  late final NoteController _controller;

  @override
  void initState() {
    super.initState();
    _controller = NoteController(
      api: widget.api,
      noteId: widget.noteId,
      actor: widget.actor,
      events: widget.ws.events,
      onSubscribe: widget.ws.subscribe,
      onUnsubscribe: widget.ws.unsubscribe,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NoteScreen(controller: _controller);
  }
}

/// Per-search route. Pops the tapped note id back to the shell so it can
/// route to the editor with the same shared API + WS clients.
class _SearchRoute extends StatefulWidget {
  const _SearchRoute({required this.api});

  final RobotNotesClient api;

  @override
  State<_SearchRoute> createState() => _SearchRouteState();
}

class _SearchRouteState extends State<_SearchRoute> {
  late final NotesSearchController _controller;

  @override
  void initState() {
    super.initState();
    _controller = NotesSearchController(api: widget.api);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SearchScreen(
      controller: _controller,
      onResultTap: (id) => Navigator.of(context).pop(id),
    );
  }
}
