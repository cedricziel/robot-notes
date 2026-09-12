import 'package:meta/meta.dart';

/// The `code`/`state` (success) or `error` (failure) query parameters
/// the OIDC provider's redirect carried back to the loopback listener.
///
/// Platform-agnostic (no `dart:io`), so both the real desktop listener
/// and the web stub can share it.
@immutable
class LoopbackRedirectResult {
  /// Creates a result from the callback request's query parameters.
  const LoopbackRedirectResult({this.code, this.state, this.error});

  /// The authorization code, present on success.
  final String? code;

  /// The `state` value, present on both success and failure.
  final String? state;

  /// The OAuth `error` code, present when the provider reports a
  /// failure instead of a code.
  final String? error;
}
