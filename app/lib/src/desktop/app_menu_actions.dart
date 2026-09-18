import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// App-wide commands the shell can perform: what the File and View menus
/// of the native macOS menu bar call into. Every handler is optional; a
/// `null` one renders its menu item disabled.
@immutable
class ShellMenuHandlers {
  const ShellMenuHandlers({
    this.newNote,
    this.newFolder,
    this.uploadFile,
    this.search,
    this.refresh,
    this.account,
  });

  final VoidCallback? newNote;
  final VoidCallback? newFolder;
  final VoidCallback? uploadFile;
  final VoidCallback? search;
  final VoidCallback? refresh;
  final VoidCallback? account;
}

/// Commands on the note currently in front: what the Note menu calls
/// into. `null` handlers render disabled, so "Save" greys out while merely
/// reading and "Edit Note" greys out while already editing — the menu bar
/// reflects the note's state the way a native document app's does.
@immutable
class NoteMenuHandlers {
  const NoteMenuHandlers({
    this.edit,
    this.save,
    this.close,
    this.move,
    this.delete,
  });

  final VoidCallback? edit;
  final VoidCallback? save;
  final VoidCallback? close;
  final VoidCallback? move;
  final VoidCallback? delete;
}

/// Commands on the database view currently in front: what the Database
/// menu calls into. `null` handlers render disabled, so New Row/Edit
/// Schema grey out once no database screen is showing.
@immutable
class DatabaseMenuHandlers {
  const DatabaseMenuHandlers({this.newRow, this.editSchema, this.close});

  final VoidCallback? newRow;
  final VoidCallback? editSchema;
  final VoidCallback? close;
}

/// The live set of handlers behind the native menu bar. Screens register
/// their handlers while they are the ones in front and withdraw them when
/// they leave; the menu bar listens and rebuilds itself.
///
/// Registration is keyed by an [owner] token (the registering `State`)
/// because Flutter unmounts a replaced screen *after* its replacement has
/// mounted: without the token, the old note's `dispose` would wipe the new
/// note's freshly registered handlers.
///
/// Screens register from `didChangeDependencies`, i.e. mid-build, while
/// the menu bar listening to this sits *above* them in the tree — and a
/// listener may not rebuild an ancestor during the build phase. A change
/// that lands mid-build is therefore announced once the frame is done;
/// one that lands outside a frame is announced at once.
class AppMenuActions extends ChangeNotifier {
  ShellMenuHandlers _shell = const ShellMenuHandlers();
  NoteMenuHandlers _note = const NoteMenuHandlers();
  DatabaseMenuHandlers _database = const DatabaseMenuHandlers();
  Object? _shellOwner;
  Object? _noteOwner;
  Object? _databaseOwner;
  bool _notifyScheduled = false;
  bool _disposed = false;

  ShellMenuHandlers get shell => _shell;
  NoteMenuHandlers get note => _note;
  DatabaseMenuHandlers get database => _database;

  /// Installs [handlers] as the shell's, on behalf of [owner].
  void setShell(Object owner, ShellMenuHandlers handlers) {
    _shellOwner = owner;
    _shell = handlers;
    _changed();
  }

  /// Withdraws the shell handlers, but only if [owner] is still the one
  /// that installed them.
  void clearShell(Object owner) {
    if (_shellOwner != owner) return;
    _shellOwner = null;
    _shell = const ShellMenuHandlers();
    _changed();
  }

  /// Installs [handlers] as the front note's, on behalf of [owner].
  void setNote(Object owner, NoteMenuHandlers handlers) {
    _noteOwner = owner;
    _note = handlers;
    _changed();
  }

  /// Withdraws the note handlers, but only if [owner] is still the one
  /// that installed them.
  void clearNote(Object owner) {
    if (_noteOwner != owner) return;
    _noteOwner = null;
    _note = const NoteMenuHandlers();
    _changed();
  }

  /// Installs [handlers] as the front database screen's, on behalf of
  /// [owner].
  void setDatabase(Object owner, DatabaseMenuHandlers handlers) {
    _databaseOwner = owner;
    _database = handlers;
    _changed();
  }

  /// Withdraws the database handlers, but only if [owner] is still the one
  /// that installed them.
  void clearDatabase(Object owner) {
    if (_databaseOwner != owner) return;
    _databaseOwner = null;
    _database = const DatabaseMenuHandlers();
    _changed();
  }

  void _changed() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Makes an [AppMenuActions] reachable from the screens below it. Screens
/// look it up with [maybeOf], which is `null` wherever the app is hosted
/// without one (widget tests that mount a single screen) so registration
/// silently becomes a no-op there.
class AppMenuActionsScope extends InheritedWidget {
  const AppMenuActionsScope({
    required this.actions,
    required super.child,
    super.key,
  });

  final AppMenuActions actions;

  /// The nearest registry, without registering a rebuild dependency: the
  /// instance never changes for the app's lifetime, and its contents are
  /// consumed through its own [Listenable] interface by the menu bar.
  static AppMenuActions? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppMenuActionsScope>()?.actions;

  @override
  bool updateShouldNotify(AppMenuActionsScope oldWidget) =>
      actions != oldWidget.actions;
}
