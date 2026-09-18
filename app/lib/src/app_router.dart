import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:go_router/go_router.dart';
import 'package:shared/shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api/api_client.dart';
import 'api/api_exceptions.dart';
import 'auth/oidc_session_refresher.dart';
import 'auth/oidc_sign_in_controller.dart';
import 'config/app_config.dart';
import 'config/config_store.dart';
import 'desktop/app_menu_actions.dart';
import 'desktop/app_menu_bar.dart';
import 'files/picked_file.dart';
import 'layout/breakpoints.dart';
import 'notes/folder_prompt.dart';
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
import 'widgets/adaptive.dart';
import 'widgets/connection_banner.dart';
import 'widgets/empty_state.dart';
import 'widgets/error_strip.dart';
import 'widgets/resizable_panel.dart';

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
/// empty content, in [path] (defaulting to the vault root). The server
/// rejects empty titles (`POST /notes` requires a non-empty string), so
/// the client always sends a stand-in; the user renames it inline once
/// the editor opens.
///
/// Extracted so widget tests can exercise the same call the FAB does
/// without having to mount the full app shell.
Future<Note> createBlankNote(
  RobotNotesClient api, {
  DateTime? now,
  String path = '',
}) {
  final title = blankNoteTitle(now ?? DateTime.now());
  return api.createNote(title: title, content: '', path: path);
}

/// Opens [pickFile] and, if the user chose a file rather than cancelling,
/// uploads it into [path] (the vault root when empty) via [api]. Returns
/// `null` when the picker was cancelled, so the caller can distinguish
/// "nothing to report" from a completed upload.
///
/// Extracted so widget tests can exercise the same call the FAB does
/// without having to mount the full app shell.
Future<UploadedFileResult?> uploadPickedFile(
  RobotNotesClient api,
  PickFile pickFile, {
  String path = '',
}) async {
  final picked = await pickFile();
  if (picked == null) return null;
  return api.uploadFile(path: path, filename: picked.name, bytes: picked.bytes);
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
///
/// `/` and `/notes/:id` share a [ShellRoute] so the three-pane layout at
/// [WindowSizeClass.large] (folders | notes list | note) can keep the
/// folder tree and the list mounted while the note pane navigates.
GoRouter buildAppRouter({
  required ConfigHolder configHolder,
  String? initialLocation,
  PickFile pickFile = pickFileViaFilePicker,
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
      ShellRoute(
        builder: (context, state, child) =>
            _AppShell(location: state.uri, pickFile: pickFile, child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => _HomePage(pickFile: pickFile),
          ),
          GoRoute(
            path: '/notes/:id',
            builder: (context, state) => _NotePage(
              noteId: state.pathParameters['id']!,
              startEditing: state.uri.queryParameters['edit'] == '1',
            ),
          ),
        ],
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

/// Whether the window is wide enough for the three-pane shell, in which
/// notes open beside the list (`go`) instead of on top of it (`push`).
bool _isLarge(BuildContext context) =>
    Breakpoints.of(context) >= WindowSizeClass.large;

/// The note id a shell location points at, or `null` on the list route.
String? _noteIdFromLocation(Uri location) {
  final segments = location.pathSegments;
  if (segments.length == 2 && segments.first == 'notes') return segments[1];
  return null;
}

/// Creates a new note in the current folder (Cmd/Ctrl+N).
class NewNoteIntent extends Intent {
  const NewNoteIntent();
}

/// Opens the search overlay (Cmd/Ctrl+K, Cmd/Ctrl+Shift+F).
class OpenSearchIntent extends Intent {
  const OpenSearchIntent();
}

/// Re-fetches the notes list (Cmd+R, F5).
class RefreshNotesIntent extends Intent {
  const RefreshNotesIntent();
}

/// Opens the account surface (Cmd/Ctrl+,).
class OpenAccountIntent extends Intent {
  const OpenAccountIntent();
}

/// App-level keyboard shortcuts, active anywhere inside the shell. Both
/// the macOS (meta) and Windows/Linux (control) chords are registered so
/// the map doesn't need to know the platform. On the macOS desktop build
/// the native menu bar owns the ⌘ chords it displays, so the shell
/// registers this map through [withoutMenuOwnedShortcuts].
const Map<ShortcutActivator, Intent> appShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyN, meta: true): NewNoteIntent(),
  SingleActivator(LogicalKeyboardKey.keyN, control: true): NewNoteIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, meta: true): OpenSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, control: true): OpenSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true):
      OpenSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true):
      OpenSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyR, meta: true): RefreshNotesIntent(),
  SingleActivator(LogicalKeyboardKey.f5): RefreshNotesIntent(),
  SingleActivator(LogicalKeyboardKey.comma, meta: true): OpenAccountIntent(),
  SingleActivator(LogicalKeyboardKey.comma, control: true): OpenAccountIntent(),
};

/// The [ShellRoute] chrome around `/` and `/notes/:id`: keyboard
/// shortcuts on every size, plus the folder sidebar and the notes list as
/// persistent panes at [WindowSizeClass.large]. Stateful so the sidebar
/// width survives navigation between notes.
class _AppShell extends StatefulWidget {
  const _AppShell({
    required this.location,
    required this.pickFile,
    required this.child,
  });

  final Uri location;
  final PickFile pickFile;
  final Widget child;

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  double _sidebarWidth = PaneSizes.sidebarDefault;
  AppMenuActions? _menuActions;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The macOS menu bar's File and View items call these; there is no
    // registry (and nothing to do) anywhere the app runs without one.
    _menuActions = AppMenuActionsScope.maybeOf(context);
    _menuActions?.setShell(
      this,
      ShellMenuHandlers(
        newNote: _newNoteInSelectedFolder,
        newFolder: _newFolderInSelectedFolder,
        uploadFile: _uploadToSelectedFolder,
        search: () => unawaited(_openSearch(context, AppSession.of(context))),
        refresh: () => unawaited(AppSession.of(context).list.refresh()),
        account: () => unawaited(_showAccount(context, AppSession.of(context))),
      ),
    );
  }

  @override
  void dispose() {
    _menuActions?.clearShell(this);
    super.dispose();
  }

  void _newNoteInSelectedFolder() {
    final session = AppSession.of(context);
    unawaited(
      _createNote(
        context,
        session,
        path: session.list.value.selectedPath ?? '',
      ),
    );
  }

  void _newFolderInSelectedFolder() {
    final session = AppSession.of(context);
    unawaited(
      _createFolder(
        context,
        session,
        initialPath: session.list.value.selectedPath,
      ),
    );
  }

  void _uploadToSelectedFolder() {
    final session = AppSession.of(context);
    unawaited(
      _uploadFile(
        context,
        session,
        pickFile: widget.pickFile,
        path: session.list.value.selectedPath ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSession.of(context);
    final large = _isLarge(context);
    return Shortcuts(
      shortcuts: withoutMenuOwnedShortcuts(appShortcuts),
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewNoteIntent: CallbackAction<NewNoteIntent>(
            onInvoke: (_) {
              _newNoteInSelectedFolder();
              return null;
            },
          ),
          OpenSearchIntent: CallbackAction<OpenSearchIntent>(
            onInvoke: (_) {
              unawaited(_openSearch(context, session));
              return null;
            },
          ),
          RefreshNotesIntent: CallbackAction<RefreshNotesIntent>(
            onInvoke: (_) {
              unawaited(session.list.refresh());
              return null;
            },
          ),
          OpenAccountIntent: CallbackAction<OpenAccountIntent>(
            onInvoke: (_) {
              unawaited(_showAccount(context, session));
              return null;
            },
          ),
        },
        // Parks focus inside the shell when nothing else holds it, so the
        // shortcuts above see key events even before the user has clicked
        // anything. A text field that later requests focus takes over as
        // usual; the scope never steals it back.
        child: FocusScope(
          autofocus: true,
          child: large ? _buildThreePane(context, session) : widget.child,
        ),
      ),
    );
  }

  Widget _buildThreePane(BuildContext context, AppSession session) {
    final scheme = Theme.of(context).colorScheme;
    final selectedNoteId = _noteIdFromLocation(widget.location);
    return ValueListenableBuilder<NotesListState>(
      valueListenable: session.list,
      builder: (context, listState, _) {
        final selectedPath = listState.selectedPath;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ResizablePanel(
              width: _sidebarWidth,
              minWidth: PaneSizes.sidebarMin,
              maxWidth: PaneSizes.sidebarMax,
              onWidthChanged: (w) => setState(() => _sidebarWidth = w),
              child: Material(
                key: const Key('shell.sidebar'),
                color: scheme.surfaceContainerLow,
                // The Material itself paints all the way up under a macOS
                // unified title bar (so the sidebar's background extends
                // behind the traffic lights); only its content — starting
                // with the "Folders" header — insets below it.
                child: SafeArea(
                  bottom: false,
                  child: FolderTreeSidebar(
                    controller: session.tree,
                    selectedPath: selectedPath,
                    onSelect: session.list.selectFolder,
                    onCreateFolder: () => unawaited(
                      _createFolder(
                        context,
                        session,
                        initialPath: selectedPath,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: PaneSizes.listPane,
              // A nested messenger so app-level SnackBars surface once, in
              // the note pane, instead of in every Scaffold of the shell.
              child: ScaffoldMessenger(
                child: NotesListScreen(
                  key: const Key('shell.list'),
                  controller: session.list,
                  layout: NotesListLayout.wide,
                  selectedNoteId: selectedNoteId,
                  onNoteTap: (id) => context.go('/notes/$id'),
                  onCreateNote: () => unawaited(
                    _createNote(context, session, path: selectedPath ?? ''),
                  ),
                  onCreateFolder: () => unawaited(
                    _createFolder(context, session, initialPath: selectedPath),
                  ),
                  onUploadFile: () => unawaited(
                    _uploadFile(
                      context,
                      session,
                      pickFile: widget.pickFile,
                      path: selectedPath ?? '',
                    ),
                  ),
                  onSearch: () => unawaited(_openSearch(context, session)),
                  onAccount: () => unawaited(_showAccount(context, session)),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: widget.child),
          ],
        );
      },
    );
  }
}

/// The `/` route. Inside the three-pane shell the list already lives in
/// its own pane, so this is just the "nothing selected" placeholder for
/// the note pane; below that, it is the full notes list screen. Reads the
/// size class in `build` so a window resize flips between the two.
class _HomePage extends StatelessWidget {
  const _HomePage({required this.pickFile});

  final PickFile pickFile;

  @override
  Widget build(BuildContext context) {
    if (_isLarge(context)) {
      return const Scaffold(
        body: EmptyState(
          key: Key('shell.detail.empty'),
          icon: Icons.notes,
          title: 'Select a note',
          message: 'Choose a note from the list, or create a new one.',
        ),
      );
    }
    return _buildListPage(context, pickFile);
  }
}

Widget _buildListPage(BuildContext context, PickFile pickFile) {
  final session = AppSession.of(context);
  return ValueListenableBuilder<NotesListState>(
    valueListenable: session.list,
    builder: (context, listState, _) {
      return NotesListScreen(
        controller: session.list,
        onNoteTap: (id) => unawaited(context.push('/notes/$id')),
        onCreateNote: () => unawaited(
          _createNote(context, session, path: listState.selectedPath ?? ''),
        ),
        onCreateFolder: () => unawaited(
          _createFolder(context, session, initialPath: listState.selectedPath),
        ),
        onUploadFile: () => unawaited(
          _uploadFile(
            context,
            session,
            pickFile: pickFile,
            path: listState.selectedPath ?? '',
          ),
        ),
        onSearch: () => unawaited(_openSearch(context, session)),
        onAccount: () => unawaited(_showAccount(context, session)),
        sidebar: FolderTreeSidebar(
          controller: session.tree,
          selectedPath: listState.selectedPath,
          onSelect: session.list.selectFolder,
          onCreateFolder: () => unawaited(
            _createFolder(
              context,
              session,
              initialPath: listState.selectedPath,
            ),
          ),
        ),
      );
    },
  );
}

/// Opens search as an overlay above the current screen instead of routing
/// to a full page — the list underneath stays mounted (no refetch, no
/// scroll-position loss) and dismissing (scrim tap, close button, or back
/// gesture) just closes the overlay. On compact windows it slides down as
/// a top sheet; from medium up it is a palette-style dialog near the top.
/// [NotesSearchController] is scoped to this call: a fresh one is created
/// per open and disposed once it closes.
Future<void> _openSearch(BuildContext context, AppSession session) async {
  final controller = NotesSearchController(api: session.api);
  final router = GoRouter.of(context);
  void openResult(BuildContext dialogContext, String id) {
    final large = _isLarge(dialogContext);
    Navigator.of(dialogContext).pop();
    if (large) {
      router.go('/notes/$id');
    } else {
      unawaited(router.push('/notes/$id'));
    }
  }

  try {
    if (Breakpoints.of(context) >= WindowSizeClass.medium) {
      await showDialog<void>(
        context: context,
        barrierLabel: 'Search',
        builder: (ctx) {
          final height = MediaQuery.sizeOf(ctx).height;
          return Dialog(
            alignment: const Alignment(0, -0.6),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 640,
                maxHeight: min(560, 0.7 * height),
              ),
              child: SizedBox.expand(
                child: SearchScreen(
                  controller: controller,
                  recentNotes: session.list.value.items,
                  onResultTap: (id) => openResult(ctx, id),
                  onClose: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          );
        },
      );
      return;
    }
    await showGeneralDialog<void>(
      context: context,
      barrierLabel: 'Search',
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              heightFactor: 0.92,
              // Swiping the sheet up (over its header or the grab handle;
              // the results list keeps vertical drags over itself) pops
              // it through the same route pop the close button uses. No
              // resize animation: the route's own exit transition removes
              // the sheet, and a collapse would trip Dismissible's
              // "still in the tree" check while it plays.
              child: Dismissible(
                key: const Key('search.sheet'),
                direction: DismissDirection.up,
                resizeDuration: null,
                onDismissed: (_) => Navigator.of(ctx).pop(),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: SearchScreen(
                          controller: controller,
                          recentNotes: session.list.value.items,
                          onResultTap: (id) => openResult(ctx, id),
                          onClose: () => Navigator.of(ctx).pop(),
                        ),
                      ),
                      const _SheetGrabHandle(key: Key('search.sheet.handle')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        );
      },
    );
  } finally {
    controller.dispose();
  }
}

/// The pill along the bottom edge of the compact search sheet: the visible
/// affordance for swiping the sheet away, painted on the same surface as
/// [SearchScreen] so it reads as part of the sheet rather than a footer.
class _SheetGrabHandle extends StatelessWidget {
  const _SheetGrabHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Semantics(
        label: 'Swipe up to close search',
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _createNote(
  BuildContext context,
  AppSession session, {
  String path = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final note = await createBlankNote(session.api, path: path);
    if (!context.mounted) return;
    final location = '/notes/${note.id}?edit=1';
    if (_isLarge(context)) {
      context.go(location);
    } else {
      unawaited(context.push(location));
    }
  } on ApiException catch (e) {
    final message = describeError(e, fallback: 'Could not create note.');
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Shows the "New folder" prompt (pre-filled with [initialPath], typically
/// the currently selected folder) and, on success, refreshes the folder
/// tree so the new (possibly empty) folder appears immediately.
Future<void> _createFolder(
  BuildContext context,
  AppSession session, {
  String? initialPath,
}) async {
  final created = await showCreateFolderDialog(
    context,
    api: session.api,
    initialPath: initialPath,
  );
  if (created) await session.tree.refresh();
}

/// Opens the file picker via [pickFile] and, unless cancelled, uploads the
/// chosen file into [path] (the currently selected folder), reporting the
/// outcome via a SnackBar — the stored filename on success, or the
/// server's error message on failure. Mirrors [_createNote]'s
/// SnackBar-on-`ApiException` convention rather than [_createFolder]'s
/// dialog, since the native picker is already the "choose what to act on"
/// UI here — there's no freeform input left for a dialog to collect.
Future<void> _uploadFile(
  BuildContext context,
  AppSession session, {
  required PickFile pickFile,
  String path = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await uploadPickedFile(session.api, pickFile, path: path);
    if (result == null) return; // user cancelled the picker
    messenger.showSnackBar(
      SnackBar(content: Text('Uploaded ${result.filename}')),
    );
  } on ApiException catch (e) {
    final message = describeError(e, fallback: 'Could not upload file.');
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Opens the account surface — a bottom sheet on compact windows, a
/// dialog from medium up — showing which server and identity this session
/// is using and the live connection state. Its "Disconnect" button closes
/// the surface and hands off to the existing confirmation prompt.
Future<void> _showAccount(BuildContext context, AppSession session) async {
  final sheet = _AccountSheet(session: session);
  final bool? disconnect;
  if (Breakpoints.of(context) >= WindowSizeClass.medium) {
    disconnect = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: sheet,
        ),
      ),
    );
  } else {
    disconnect = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(top: false, child: sheet),
    );
  }
  if ((disconnect ?? false) && context.mounted) {
    await _confirmReset(context, session);
  }
}

/// Body of the account bottom sheet / dialog. Pops with `true` when the
/// user asks to disconnect; the caller runs the confirmation.
class _AccountSheet extends StatelessWidget {
  const _AccountSheet({required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('account.sheet'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Account', style: theme.textTheme.titleLarge),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(session.baseUrl, key: const Key('account.server')),
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Display name'),
            subtitle: Text(session.actor, key: const Key('account.actor')),
          ),
          ValueListenableBuilder<ConnectionStatus>(
            valueListenable: session.connection,
            builder: (context, status, _) {
              final (IconData icon, String label) = switch (status) {
                ConnectionStatus.connected => (
                  Icons.cloud_done_outlined,
                  'Connected',
                ),
                ConnectionStatus.reconnecting => (Icons.sync, 'Reconnecting…'),
                ConnectionStatus.stale => (Icons.cloud_off, 'Connection lost'),
              };
              return ListTile(
                leading: Icon(icon),
                title: const Text('Connection'),
                subtitle: Text(label, key: const Key('account.connection')),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.tonalIcon(
              key: const Key('account.disconnect'),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.logout),
              label: const Text('Disconnect'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmReset(BuildContext context, AppSession session) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: const Text('Disconnect from server?'),
      content: const Text(
        'This clears the saved server URL, API key, and display name. '
        "You'll be asked to reconnect next time.",
      ),
      actions: [
        adaptiveDialogAction(
          ctx,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        adaptiveDialogAction(
          ctx,
          key: const Key('account.disconnect.confirm'),
          primary: true,
          destructive: true,
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

/// The `/notes/:id` route. Keyed on the note id so `go`-ing from one note
/// to another inside the shell (same page key) remounts [NoteRoute] and
/// its controller instead of updating a controller bound to the old id.
/// Reads the size class in `build`, so a resize across the large boundary
/// switches the close affordance between "back" (page) and "close" (pane).
class _NotePage extends StatelessWidget {
  const _NotePage({required this.noteId, required this.startEditing});

  final String noteId;
  final bool startEditing;

  @override
  Widget build(BuildContext context) {
    final session = AppSession.of(context);
    final large = _isLarge(context);
    return NoteRoute(
      key: ValueKey<String>(noteId),
      api: session.api,
      ws: session.ws,
      actor: session.actor,
      noteId: noteId,
      startEditing: startEditing,
      presentation: large ? NotePresentation.pane : NotePresentation.page,
      onClosed: (saved) => _handleNoteClosed(context, session, saved),
      // Backlinks open the referencing note: beside the list in the shell,
      // or on top of the current note (a further close pops back here).
      onOpenNote: (id) {
        if (_isLarge(context)) {
          context.go('/notes/$id');
        } else {
          unawaited(context.push('/notes/$id'));
        }
      },
      // Tag filtering is a list-view concern: scope the list, then go there
      // directly (replacing this route, like a search-result tap does).
      onTagTap: (tag) {
        unawaited(session.list.selectTag(tag));
        context.go('/');
      },
    );
  }
}

/// The list only learns about a save through the realtime stream, which is
/// not always connected — refresh explicitly, but only when a save actually
/// happened, so viewing a note doesn't cost an extra fetch on every close.
///
/// Only needed on the `canPop()` and shell branches: the no-history branch
/// remounts [NotesListScreen], which already refreshes itself in `initState`.
void _handleNoteClosed(BuildContext context, AppSession session, bool saved) {
  if (_isLarge(context)) {
    // The list stays mounted beside the note pane; closing just empties
    // the pane.
    if (saved) unawaited(session.list.refresh());
    context.go('/');
  } else if (context.canPop()) {
    if (saved) unawaited(session.list.refresh());
    context.pop();
  } else {
    // A deep-linked note (reload, bookmark, or a search hit reached via
    // `go`) has no history to pop back into.
    context.go('/');
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
    this.presentation = NotePresentation.page,
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

  /// Whether the note is a full page (back arrow) or the detail pane of
  /// the three-pane shell (close button).
  final NotePresentation presentation;

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
      presentation: widget.presentation,
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
    required this.baseUrl,
    required this.connection,
    required this.onReset,
    required super.child,
    super.key,
  });

  final RobotNotesClient api;
  final RobotNotesWsClient ws;
  final NotesListController list;
  final FolderTreeController tree;
  final String actor;

  /// The connected server's origin, for display in the account surface.
  final String baseUrl;

  /// Live realtime connection state, for the account surface. The banner
  /// above the routed content renders the same value.
  final ValueListenable<ConnectionStatus> connection;

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
      baseUrl: widget.config.baseUrl,
      connection: _status,
      onReset: widget.onReset,
      child: Column(
        children: [
          ConnectionBanner(status: _status),
          Expanded(
            child: ValueListenableBuilder<ConnectionStatus>(
              valueListenable: _status,
              // The banner already sits inside a SafeArea, so while it is
              // visible the AppBar below must not reserve status-bar space
              // a second time.
              builder: (context, status, child) =>
                  status == ConnectionStatus.connected
                  ? child!
                  : MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: child!,
                    ),
              child: widget.child,
            ),
          ),
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
    return const Scaffold(
      body: Center(child: CircularProgressIndicator.adaptive()),
    );
  }
}
