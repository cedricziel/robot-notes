import 'package:flutter/widgets.dart';

class NoteNavigationRegistry {
  Object? _owner;
  Uri? _location;
  Future<bool> Function()? _leave;
  Future<bool>? _pending;

  void register(Object owner, Uri location, Future<bool> Function() leave) {
    _owner = owner;
    _location = location;
    _leave = leave;
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _location = null;
    _leave = null;
  }

  Future<String?> redirect(Uri destination) async {
    final location = _location;
    final leave = _leave;
    final owner = _owner;
    if (location == null || location == destination || leave == null) {
      return null;
    }
    final pending = _pending ??= leave();
    try {
      final allowed = await pending;
      if (allowed && identical(_owner, owner)) unregister(owner!);
      return allowed ? null : location.toString();
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }
}

class NoteNavigationScope extends InheritedWidget {
  const NoteNavigationScope({
    required this.registry,
    required this.location,
    required super.child,
    super.key,
  });

  final NoteNavigationRegistry registry;
  final Uri location;

  static NoteNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteNavigationScope>();

  @override
  bool updateShouldNotify(NoteNavigationScope oldWidget) =>
      registry != oldWidget.registry || location != oldWidget.location;
}
