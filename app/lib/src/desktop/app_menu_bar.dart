import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import 'app_menu_actions.dart';

/// Whether the app owns a native menu bar on this platform: only the macOS
/// desktop build (Flutter's [PlatformMenuBar] supports nothing else, and
/// a Mac browser tab has the browser's menus).
bool get nativeMenuBarActive =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Installs the app's menus into the macOS menu bar, and does nothing on
/// every other platform. Rebuilds — and re-sends the menu to the OS —
/// whenever [actions] changes, so items grey out and light up as screens
/// come and go.
///
/// [onCloseWindow] backs the Window › Close Window item (⌘W); `null` hides
/// the item.
class AppMenuBar extends StatelessWidget {
  const AppMenuBar({
    required this.actions,
    required this.child,
    this.onCloseWindow,
    super.key,
  });

  final AppMenuActions actions;
  final Widget child;
  final VoidCallback? onCloseWindow;

  @override
  Widget build(BuildContext context) {
    // Not merely an optimisation: the provided items (About, Quit, …)
    // refuse to serialize for any platform but macOS.
    if (!nativeMenuBarActive) return child;
    return ListenableBuilder(
      listenable: actions,
      builder: (context, _) => PlatformMenuBar(
        menus: buildAppMenus(actions, onCloseWindow: onCloseWindow),
        child: child,
      ),
    );
  }
}

/// The menu tree, as a pure function of the current handlers so tests can
/// inspect labels, shortcuts, and which items are enabled.
///
/// Every item that has a keyboard shortcut in the app (New Note, Search,
/// Refresh, Save, Edit Note) carries it here too, so the menu displays it
/// the way a Mac user expects. On macOS the menu bar then *owns* those
/// chords — see [menuOwnsShortcut] — so a press reaches exactly one
/// handler.
List<PlatformMenuItem> buildAppMenus(
  AppMenuActions actions, {
  VoidCallback? onCloseWindow,
}) {
  final shell = actions.shell;
  final note = actions.note;
  return <PlatformMenuItem>[
    PlatformMenu(
      label: 'robot-notes',
      menus: <PlatformMenuItem>[
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.about,
        ),
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(
              label: 'Account…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: shell.account,
            ),
          ],
        ),
        const PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.servicesSubmenu,
            ),
          ],
        ),
        const PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hideOtherApplications,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.showAllApplications,
            ),
          ],
        ),
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
      ],
    ),
    PlatformMenu(
      label: 'File',
      menus: <PlatformMenuItem>[
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(
              label: 'New Note',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
              ),
              onSelected: shell.newNote,
            ),
            PlatformMenuItem(
              label: 'New Folder…',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
                shift: true,
              ),
              onSelected: shell.newFolder,
            ),
            PlatformMenuItem(
              label: 'Upload File…',
              onSelected: shell.uploadFile,
            ),
          ],
        ),
        PlatformMenuItem(
          label: 'Save',
          shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
          onSelected: note.save,
        ),
      ],
    ),
    PlatformMenu(
      label: 'Edit',
      menus: <PlatformMenuItem>[
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            _editingItem(
              'Undo',
              const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
              const UndoTextIntent(SelectionChangedCause.keyboard),
            ),
            _editingItem(
              'Redo',
              const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                shift: true,
              ),
              const RedoTextIntent(SelectionChangedCause.keyboard),
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            _editingItem(
              'Cut',
              const SingleActivator(LogicalKeyboardKey.keyX, meta: true),
              const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
            ),
            _editingItem(
              'Copy',
              const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
              CopySelectionTextIntent.copy,
            ),
            _editingItem(
              'Paste',
              const SingleActivator(LogicalKeyboardKey.keyV, meta: true),
              const PasteTextIntent(SelectionChangedCause.keyboard),
            ),
            _editingItem(
              'Select All',
              const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
              const SelectAllTextIntent(SelectionChangedCause.keyboard),
            ),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: 'View',
      menus: <PlatformMenuItem>[
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(
              label: 'Search',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyK,
                meta: true,
              ),
              onSelected: shell.search,
            ),
            PlatformMenuItem(
              label: 'Refresh',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyR,
                meta: true,
              ),
              onSelected: shell.refresh,
            ),
          ],
        ),
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.toggleFullScreen,
        ),
      ],
    ),
    PlatformMenu(
      label: 'Note',
      menus: <PlatformMenuItem>[
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(
              label: 'Edit Note',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyE,
                meta: true,
              ),
              onSelected: note.edit,
            ),
            PlatformMenuItem(label: 'Close Note', onSelected: note.close),
          ],
        ),
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(label: 'Move to Folder…', onSelected: note.move),
            PlatformMenuItem(label: 'Delete Note', onSelected: note.delete),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: 'Window',
      menus: <PlatformMenuItem>[
        const PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
          ],
        ),
        if (onCloseWindow != null)
          PlatformMenuItem(
            label: 'Close Window',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyW,
              meta: true,
            ),
            onSelected: onCloseWindow,
          ),
      ],
    ),
  ];
}

/// An Edit-menu item that forwards a text-editing [intent] to whatever
/// has keyboard focus — a text field, or the note body's selection area —
/// and does nothing when nothing focused can handle it.
///
/// [PlatformMenuItem.onSelectedIntent] would do the same, but it asserts
/// that something holds focus; a plain callback tolerates the moment
/// between screens when nothing does.
PlatformMenuItem _editingItem(
  String label,
  SingleActivator shortcut,
  Intent intent,
) => PlatformMenuItem(
  label: label,
  shortcut: shortcut,
  onSelected: () {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null) Actions.maybeInvoke(context, intent);
  },
);

/// The ⌘-chords the menu bar claims when it is active: those on the
/// File/View/Note items above, as (trigger, shift) pairs. (The Edit menu's
/// are left out on purpose: text fields handle those themselves, first,
/// and only an unhandled press falls through to the menu.)
final _menuOwnedTriggers = <LogicalKeyboardKey, Set<bool>>{
  LogicalKeyboardKey.keyN: {false, true},
  LogicalKeyboardKey.keyS: {false},
  LogicalKeyboardKey.keyK: {false},
  LogicalKeyboardKey.keyR: {false},
  LogicalKeyboardKey.keyE: {false},
  LogicalKeyboardKey.keyW: {false},
  LogicalKeyboardKey.comma: {false},
};

/// Whether the native menu bar, when active, handles [activator] itself.
/// True only for the plain ⌘ (or ⇧⌘) chords listed on its items; Ctrl
/// chords and everything else stay with the in-app [Shortcuts].
bool menuOwnsShortcut(ShortcutActivator activator) {
  if (activator is! SingleActivator) return false;
  if (!activator.meta || activator.control || activator.alt) return false;
  return _menuOwnedTriggers[activator.trigger]?.contains(activator.shift) ??
      false;
}

/// [bindings] minus the chords the native menu bar owns on this platform,
/// so a keypress fires exactly one of the two. Returns [bindings] itself
/// where there is no native menu bar.
Map<ShortcutActivator, T> withoutMenuOwnedShortcuts<T>(
  Map<ShortcutActivator, T> bindings,
) {
  if (!nativeMenuBarActive) return bindings;
  return <ShortcutActivator, T>{
    for (final entry in bindings.entries)
      if (!menuOwnsShortcut(entry.key)) entry.key: entry.value,
  };
}
