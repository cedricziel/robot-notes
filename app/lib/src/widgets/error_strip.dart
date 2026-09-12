import 'package:flutter/material.dart';

import '../api/api_exceptions.dart';

/// Non-blocking error strip rendered above a list so already-loaded
/// content stays visible. [onRetry] adds a "Retry" button when given.
class ErrorStrip extends StatelessWidget {
  const ErrorStrip({required this.message, this.onRetry, super.key});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// The server's `message` when [error] is an [ApiException] that carries
/// one, otherwise [fallback]. Non-API failures (socket errors, bad JSON)
/// have no user-facing text of their own.
String describeError(Object error, {required String fallback}) {
  final message = error is ApiException ? error.message : null;
  return message == null || message.isEmpty ? fallback : message;
}
