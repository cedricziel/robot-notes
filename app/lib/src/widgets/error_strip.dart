import 'package:flutter/material.dart';

import '../api/api_exceptions.dart';
import 'status_strip.dart';

/// Non-blocking error strip rendered above a list so already-loaded
/// content stays visible. [onRetry] adds a "Retry" button when given.
///
/// A thin preset over [StatusStrip] kept for the many call sites that only
/// ever need the error tone.
class ErrorStrip extends StatelessWidget {
  const ErrorStrip({required this.message, this.onRetry, super.key});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return StatusStrip(
      message: message,
      tone: StatusTone.error,
      icon: Icons.error_outline,
      action: onRetry == null
          ? null
          : TextButton(onPressed: onRetry, child: const Text('Retry')),
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
