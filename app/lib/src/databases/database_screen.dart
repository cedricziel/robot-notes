import 'package:flutter/material.dart';

/// The `/databases/{id}` route's content pane.
///
/// This is a routing stub (task 2.1 of `add-database-views`): it only
/// shows which database and view were resolved from the URL, plus a close
/// affordance matching `NoteScreen`'s. Group 5 replaces the body with the
/// real table/list/board rendering once the controllers from groups 3-4
/// land; nothing here should be load-bearing for that work beyond the
/// constructor shape (`id`, `viewName`, `onClose`).
class DatabaseScreen extends StatelessWidget {
  const DatabaseScreen({
    required this.id,
    this.viewName,
    this.onClose,
    super.key,
  });

  /// The database id from the `/databases/:id` path parameter.
  final String id;

  /// The view name from the `?view=` query parameter, or `null` when the
  /// URL named none and the default view applies.
  final String? viewName;

  /// Called when the user dismisses the screen (close button or a system
  /// back gesture). Defaults to a plain [Navigator] pop so pushing this
  /// widget directly, as a test might, keeps working without a router.
  final VoidCallback? onClose;

  void _close(BuildContext context) {
    final onClose = this.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Database'),
        leading: IconButton(
          key: const Key('database.close'),
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => _close(context),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Database $id', key: const Key('database.id')),
            Text(
              'View: ${viewName ?? '(default)'}',
              key: const Key('database.view'),
            ),
          ],
        ),
      ),
    );
  }
}
