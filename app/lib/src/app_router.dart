import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared/shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api/api_client.dart';
import 'api/api_exceptions.dart';
import 'auth/oidc_session_refresher.dart';
import 'auth/oidc_sign_in_controller.dart';
import 'config/app_config.dart';
import 'config/config_store.dart';
import 'notes/folder_tree_controller.dart';
import 'notes/folder_tree_sidebar.dart';
import 'notes/note_controller.dart';
import 'notes/note_screen.dart';
import 'notes/notes_list_controller.dart';
import 'notes/notes_list_screen.dart';
import 'otel/otel_http_client.dart';
import 'realtime/connection_status.dart';
import 'realtime/ws_client.dart';
import 'search/search_controller.dart';
import 'search/search_screen.dart';
import 'setup/setup_controller.dart';
import 'setup/setup_screen.dart';
import 'widgets/connection_banner.dart';
import 'widgets/error_strip.dart';

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

/// Tracks whether a persisted [AppConfig] exists and lets the setup flow
/// (or a "disconnect" action) change it at runtime. A [ChangeNotifier] so
/// [GoRouter]'s `refreshListenable` re-evaluates redirects whenever the
/// answer changes — first-run completing, or a manual disconnect.
class ConfigHolder extends ChangeNotifier {
  ConfigHolder(this._store) {
    unawaited(_load());
  }

  /// Starts already resolved, for tests that don't want to race a real
  /// [ConfigStore] read.
  ConfigHolder.seeded(this.config)
    : _store = InMemoryConfigStore(),
      loaded = true;

  final ConfigStore _store;
  final OidcSessionRefresher _refresher = OidcSessionRefresher(
    clientFactory: tracingHttpClient,
  );

  /// The store backing this holder, so callers that already have a
  /// [ConfigHolder] don't need it threaded through separately.
  ConfigStore get store => _store;

  /// Drives the setup screen's "Sign in" option and, on web, resumes a
  /// same-origin sign-in redirect on startup (see [_loadAndRefresh]).
  late final OidcSignInController oidcSignIn = OidcSignInController(
    store: _store,
    launchUri: launchOidcUri,
  );

  AppConfig? config;

  /// False until the initial [ConfigStore.read] resolves. Routing holds on
  /// a splash screen while this is false so it never flashes the setup
  /// screen before knowing whether a config is already saved.
  bool loaded = false;

  Future<void> _load() async {
    config = await _loadAndRefresh();
    loaded = true;
    notifyListeners();
  }

  /// Reads the persisted config and, for an OIDC session, refreshes its
  /// access token before use (refreshing unconditionally on load is
  /// simpler than tracking expiry). A rejected refresh token means the
  /// session is no longer valid: the stored config is cleared and the
  /// caller falls back to the setup screen exactly as if nothing had ever
  /// been persisted.
  ///
  /// On web, when nothing is persisted, this also resumes a web sign-in
  /// left in progress by a same-origin redirect back to the app (see
  /// [OidcSignInController.resumeWebSignInIfPending]) before falling back
  /// to the setup screen.
  Future<AppConfig?> _loadAndRefresh() async {
    final stored = await _store.read();
    if (stored != null) {
      if (!stored.isOidcSession) return stored;
      try {
        final refreshed = await _refresher.refresh(stored);
        await _store.write(refreshed);
        return refreshed;
      } on OidcRefreshException {
        await _store.clear();
        return null;
      }
    }

    if (kIsWeb) {
      await oidcSignIn.resumeWebSignInIfPending(Uri.base);
      final resumed = oidcSignIn.value;
      if (resumed is OidcSignInSuccess) return resumed.config;
    }
    return null;
  }

  void set(AppConfig value) {
    config = value;
    loaded = true;
    notifyListeners();
  }

  Future<void> reset() async {
    await _store.clear();
    config = null;
    notifyListeners();
  }

  @override
  void dispose() {
    oidcSignIn.dispose();
    super.dispose();
  }
}

/// Opens [uri] for the user during OIDC sign-in: the system browser as an
/// external application on desktop/mobile, or a same-tab navigation
/// (`_self`) on web so the reload-based flow in
/// [OidcSignInController.resumeWebSignInIfPending] sees the redirect back
/// on the same tab rather than a new one.
Future<void> launchOidcUri(Uri uri) => launchUrl(
  uri,
  mode: LaunchMode.externalApplication,
  webOnlyWindowName: kIsWeb ? '_self' : null,
);

/// Redirects any location to `/setup` while no config is stored, remembering
/// the originally requested location in a `from` query parameter; once setup
/// completes, sends the user on to wherever they were headed.
FutureOr<String?> _redirect(ConfigHolder configHolder, GoRouterState state) {
  if (!configHolder.loaded) return null;
  final atSetup = state.matchedLocation == '/setup';
  if (configHolder.config == null) {
    if (atSetup) return null;
    return '/setup?from=${Uri.encodeQueryComponent(state.uri.toString())}';
  }
  if (atSetup) {
    final from = state.uri.queryParameters['from'];
    return from == null || from.isEmpty ? '/' : from;
  }
  return null;
}

/// Builds the app's [GoRouter]. A single instance lives for the app's
/// lifetime; [ConfigHolder] drives redirects as the config comes and goes.
GoRouter buildAppRouter({
  required ConfigHolder configHolder,
  String? initialLocation,
}) {
  // go_router 18 defaults this to false for backward compatibility, which
  // means `context.push`/`pushReplacement` (used below for notes and search)
  // navigate internally but leave the browser URL on the previous route.
  // Every pushed route here is itself deep-link-able, so reflecting it is
  // safe and required for bookmarking, sharing, and reload-to-same-note.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  return GoRouter(
    initialLocation: initialLocation ?? '/',
    refreshListenable: configHolder,
    redirect: (context, state) => _redirect(configHolder, state),
    routes: [
      GoRoute(path: '/', builder: (context, state) => _buildListPage(context)),
      GoRoute(
        path: '/notes/:id',
        builder: (context, state) => _buildNotePage(context, state),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) =>
            _SearchRoutePage(api: AppSession.of(context).api),
      ),
      GoRoute(
        path: '/setup',
        builder: (context, state) => _SetupRoute(
          store: configHolder.store,
          oidcController: configHolder.oidcSignIn,
          onConfigured: configHolder.set,
        ),
      ),
    ],
  );
}

Widget _buildListPage(BuildContext context) {
  final session = AppSession.of(context);
  return ValueListenableBuilder<NotesListState>(
    valueListenable: session.list,
    builder: (context, listState, _) {
      return NotesListScreen(
        controller: session.list,
        onNoteTap: (id) => unawaited(context.push('/notes/$id')),
        onCreate: () => unawaited(_createNote(context, session)),
        onSearch: () => unawaited(context.push('/search')),
        onAccount: () => unawaited(_confirmReset(context, session)),
        sidebar: FolderTreeSidebar(
          controller: session.tree,
          selectedPath: listState.selectedPath,
          onSelect: session.list.selectFolder,
        ),
        appBarActions: [
          IconButton(
            key: const Key('shell.refresh'),
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: session.list.refresh,
          ),
          IconButton(
            key: const Key('shell.search'),
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => unawaited(context.push('/search')),
          ),
          IconButton(
            key: const Key('shell.reset'),
            tooltip: 'Disconnect',
            icon: const Icon(Icons.logout),
            onPressed: () => unawaited(_confirmReset(context, session)),
          ),
        ],
      );
    },
  );
}

Future<void> _createNote(BuildContext context, AppSession session) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final note = await createBlankNote(session.api);
    if (!context.mounted) return;
    unawaited(context.push('/notes/${note.id}?edit=1'));
  } on ApiException catch (e) {
    final message = describeError(e, fallback: 'Could not create note.');
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

Future<void> _confirmReset(BuildContext context, AppSession session) async {
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
  if ((confirmed ?? false) && context.mounted) {
    session.onReset();
  }
}

Widget _buildNotePage(BuildContext context, GoRouterState state) {
  final session = AppSession.of(context);
  return NoteRoute(
    api: session.api,
    ws: session.ws,
    actor: session.actor,
    noteId: state.pathParameters['id']!,
    startEditing: state.uri.queryParameters['edit'] == '1',
    onClosed: (saved) => _handleNoteClosed(context, session, saved),
    // Backlinks open the referencing note on top of the current one, same
    // as tapping a note in the list — a further close pops back here.
    onOpenNote: (id) => unawaited(context.push('/notes/$id')),
    // Tag filtering is a list-view concern: scope the list, then go there
    // directly (replacing this route, like a search-result tap does).
    onTagTap: (tag) {
      unawaited(session.list.selectTag(tag));
      context.go('/');
    },
  );
}

/// The list only learns about a save through the realtime stream, which is
/// not always connected — refresh explicitly, but only when a save actually
/// happened, so viewing a note doesn't cost an extra fetch on every close.
///
/// Only needed on the `canPop()` branch: the no-history branch remounts
/// [NotesListScreen], which already refreshes itself in `initState`.
void _handleNoteClosed(BuildContext context, AppSession session, bool saved) {
  if (context.canPop()) {
    if (saved) unawaited(session.list.refresh());
    context.pop();
  } else {
    // A deep-linked note (reload, bookmark, or a search hit reached via
    // `go`) has no history to pop back into.
    context.go('/');
  }
}

/// Per-search route. Owns [NotesSearchController] for as long as the search
/// screen is on screen.
class _SearchRoutePage extends StatefulWidget {
  const _SearchRoutePage({required this.api});

  final RobotNotesClient api;

  @override
  State<_SearchRoutePage> createState() => _SearchRoutePageState();
}

class _SearchRoutePageState extends State<_SearchRoutePage> {
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
      // Replaces the current location rather than pushing on top of it, so
      // closing the note lands back on whatever opened search (usually the
      // list) instead of back on the search screen.
      onResultTap: (id) => context.go('/notes/$id'),
    );
  }
}

/// Owns the [SetupController] for as long as the setup screen is on screen.
/// The controller persists the validated [AppConfig] itself; this widget
/// just relays the [SetupSuccess] up to the [ConfigHolder].
class _SetupRoute extends StatefulWidget {
  const _SetupRoute({
    required this.store,
    required this.oidcController,
    required this.onConfigured,
  });

  final ConfigStore store;
  final OidcSignInController oidcController;
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
      oidcController: widget.oidcController,
      onConfigured: widget.onConfigured,
    );
  }
}

/// Per-note route. The controller's lifetime is tied to this widget so
/// pushing/popping a note cleanly acquires/releases its WS subscription
/// and any held lock.
///
/// Public only so widget tests can push it onto a real Navigator.
@visibleForTesting
class NoteRoute extends StatefulWidget {
  const NoteRoute({
    required this.api,
    required this.ws,
    required this.actor,
    required this.noteId,
    this.startEditing = false,
    this.onClosed,
    this.onOpenNote,
    this.onTagTap,
    super.key,
  });

  final RobotNotesClient api;
  final RobotNotesWsClient ws;
  final String actor;
  final String noteId;
  final bool startEditing;

  /// Called when the user taps a backlink entry in the note view, with the
  /// referencing note's id.
  final ValueChanged<String>? onOpenNote;

  /// Called when the user taps a tag chip in the note view, with that tag.
  final ValueChanged<String>? onTagTap;

  /// Called once the note view is dismissed (close, delete, or a system
  /// back gesture) with whether the open note's version changed since it
  /// loaded. Defaults to a plain [Navigator] pop, so pushing this widget
  /// directly (as existing tests do) keeps working without a router.
  final ValueChanged<bool>? onClosed;

  @override
  State<NoteRoute> createState() => _NoteRouteState();
}

class _NoteRouteState extends State<NoteRoute> {
  late final NoteController _controller;
  int? _openedVersion;

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
    _controller.addListener(_captureOpenedVersion);
  }

  /// Remembers the version the note had when it first loaded, so [_close]
  /// can tell whether a save happened while it was open. Detaches itself
  /// once captured — nothing left for it to do for the rest of the note's
  /// lifetime.
  void _captureOpenedVersion() {
    _openedVersion ??= _controller.value.note?.version;
    if (_openedVersion != null) {
      _controller.removeListener(_captureOpenedVersion);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_captureOpenedVersion);
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    final saved =
        _openedVersion != null &&
        _controller.value.note?.version != _openedVersion;
    final onClosed = widget.onClosed;
    if (onClosed != null) {
      onClosed(saved);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NoteScreen(
      controller: _controller,
      onClose: _close,
      startEditing: widget.startEditing,
      onOpenNote: widget.onOpenNote,
      onTagTap: widget.onTagTap,
    );
  }
}

/// Cross-screen session state: the shared [RobotNotesClient] and
/// [RobotNotesWsClient] for the connected server, plus the singleton
/// [NotesListController] that needs to survive navigation between routes.
class AppSession extends InheritedWidget {
  const AppSession({
    required this.api,
    required this.ws,
    required this.list,
    required this.tree,
    required this.actor,
    required this.onReset,
    required super.child,
    super.key,
  });

  final RobotNotesClient api;
  final RobotNotesWsClient ws;
  final NotesListController list;
  final FolderTreeController tree;
  final String actor;
  final VoidCallback onReset;

  static AppSession of(BuildContext context) {
    final session = context.dependOnInheritedWidgetOfExactType<AppSession>();
    assert(session != null, 'No AppSession found in context');
    return session!;
  }

  // All fields are `late final` and [SessionHost] is keyed on the config, so
  // a given AppSession instance's fields never change identity — there is
  // never anything for dependents to react to.
  @override
  bool updateShouldNotify(AppSession oldWidget) => false;
}

/// Owns the singleton [RobotNotesClient], [RobotNotesWsClient],
/// [NotesListController], and [ConnectionStatusController] for as long as
/// [config] stays the same identity — recreated (via the caller's
/// [ValueKey]) whenever the user reconfigures or reconnects.
///
/// Also hoists [ConnectionBanner] above [child] so it shows on every routed
/// screen rather than only the notes list.
class SessionHost extends StatefulWidget {
  const SessionHost({
    required this.config,
    required this.onReset,
    required this.child,
    super.key,
  });

  final AppConfig config;
  final VoidCallback onReset;
  final Widget child;

  @override
  State<SessionHost> createState() => _SessionHostState();
}

class _SessionHostState extends State<SessionHost> {
  late final RobotNotesClient _api;
  late final RobotNotesWsClient _ws;
  late final NotesListController _list;
  late final FolderTreeController _tree;
  late final ConnectionStatusController _status;

  @override
  void initState() {
    super.initState();
    _api = RobotNotesClient(
      config: widget.config,
      httpClient: tracingHttpClient(),
    );
    _ws = RobotNotesWsClient(config: widget.config);
    _list = NotesListController(api: _api, events: _ws.events);
    _tree = FolderTreeController(api: _api, events: _ws.events);
    _status = ConnectionStatusController(
      events: _ws.events,
      onStaleReconnect: _list.refresh,
    );
    unawaited(_ws.start());
    // Wildcard subscription keeps the list in sync with everyone's writes.
    _ws.subscribe('*');
  }

  @override
  void dispose() {
    _status.dispose();
    _tree.dispose();
    _list.dispose();
    unawaited(_ws.dispose());
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppSession(
      api: _api,
      ws: _ws,
      list: _list,
      tree: _tree,
      actor: widget.config.actor,
      onReset: widget.onReset,
      child: Column(
        children: [
          ConnectionBanner(status: _status),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

/// Wraps the routed content for [MaterialApp.router]'s `builder`: a splash
/// while the persisted config is still loading, the raw routed [child]
/// while none is configured (the router has already sent it to `/setup`),
/// or a [SessionHost] once one exists.
class AppRouterShell extends StatelessWidget {
  const AppRouterShell({
    required this.configHolder,
    required this.child,
    super.key,
  });

  final ConfigHolder configHolder;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: configHolder,
      builder: (context, _) {
        final content = child ?? const SizedBox.shrink();
        if (!configHolder.loaded) return const _Splash();
        final config = configHolder.config;
        if (config == null) return content;
        return SessionHost(
          key: ValueKey<AppConfig>(config),
          config: config,
          onReset: configHolder.reset,
          child: content,
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
