import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth/oidc_sign_in_controller.dart';
import '../auth/server_capabilities.dart';
import '../config/app_config.dart';
import 'setup_controller.dart';

/// First-run flow, split into two steps: pick a server, then log in.
/// Step 1 is just the server URL and a Continue button. Step 2 offers — on
/// web/desktop, when the entered server advertises OIDC support — a "Sign
/// in" option, plus manual API-key entry as the always-available fallback.
/// Renders the controllers' state directly: error banner on
/// [SetupFailed]/[OidcSignInFailed], spinner on
/// [SetupSubmitting]/[OidcSignInInProgress], and on success (either path)
/// hands the validated config back to [onConfigured].
///
/// The controllers are injected (rather than read from Riverpod) so
/// widget tests can drive deterministic, mocked-http instances.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.controller,
    required this.onConfigured,
    this.oidcController,
    this.capabilitiesClientFactory = http.Client.new,
    this.capabilitiesDebounce = const Duration(milliseconds: 500),
    super.key,
  });

  final SetupController controller;
  final ValueChanged<AppConfig> onConfigured;

  /// Drives the "Sign in" option. `null` disables it entirely (still
  /// falls back to manual key entry only) — every production call site
  /// supplies one; tests that don't care about sign-in may omit it.
  final OidcSignInController? oidcController;

  /// Builds the HTTP client used to check server capabilities.
  final http.Client Function() capabilitiesClientFactory;

  /// How long to wait after the user stops typing the server URL before
  /// checking its capabilities.
  final Duration capabilitiesDebounce;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

/// Whether the current platform can run the app's own OAuth-client sign-in
/// flow. Desktop and web only, per proposal.md - Non-goals (mobile is a
/// follow-up: no loopback listener and no same-origin reload semantics
/// there). Uses `defaultTargetPlatform` rather than `dart:io`'s
/// `Platform` so this check compiles for web.
bool _isMobilePlatform() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

enum _SetupStep { server, login }

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _actor;
  Timer? _capabilitiesDebounce;
  ServerCapabilities _capabilities = ServerCapabilities.none;
  _SetupStep _step = _SetupStep.server;

  @override
  void initState() {
    super.initState();
    // On web the bundle is served from the same origin as the API, so we
    // pre-fill the URL field with the current origin and the user only
    // has to enter the API key + display name. The field is still
    // editable in case they want to point a same-origin web build at a
    // different backend (rare, but cheap to allow).
    _baseUrl = TextEditingController(text: kIsWeb ? Uri.base.origin : '');
    _apiKey = TextEditingController();
    _actor = TextEditingController();
    widget.controller.addListener(_onState);
    widget.oidcController?.addListener(_onOidcState);
    _baseUrl.addListener(_onBaseUrlChanged);
    _checkCapabilities();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onState);
    widget.oidcController?.removeListener(_onOidcState);
    _baseUrl.removeListener(_onBaseUrlChanged);
    _capabilitiesDebounce?.cancel();
    _baseUrl.dispose();
    _apiKey.dispose();
    _actor.dispose();
    super.dispose();
  }

  void _onBaseUrlChanged() {
    _capabilitiesDebounce?.cancel();
    _capabilitiesDebounce = Timer(
      widget.capabilitiesDebounce,
      _checkCapabilities,
    );
  }

  void _continue() {
    setState(() => _step = _SetupStep.login);
  }

  void _changeServer() {
    // A stale failure from the previous server shouldn't reappear once the
    // user has pointed the form at a different one.
    if (widget.controller.value is SetupFailed) {
      widget.controller.value = const SetupIdle();
    }
    if (widget.oidcController?.value is OidcSignInFailed) {
      widget.oidcController!.value = const OidcSignInIdle();
    }
    setState(() => _step = _SetupStep.server);
  }

  Future<void> _checkCapabilities() async {
    if (_isMobilePlatform() || widget.oidcController == null) return;
    final baseUrl = _baseUrl.text.trim();
    if (baseUrl.isEmpty) return;
    final client = widget.capabilitiesClientFactory();
    final ServerCapabilities caps;
    try {
      caps = await fetchServerCapabilities(baseUrl, client: client);
    } finally {
      client.close();
    }
    if (!mounted) return;
    setState(() => _capabilities = caps);
  }

  void _onState() {
    final s = widget.controller.value;
    if (s is SetupSuccess) {
      widget.onConfigured(s.config);
    }
    setState(() {});
  }

  void _onOidcState() {
    final s = widget.oidcController?.value;
    if (s is OidcSignInSuccess) {
      widget.onConfigured(s.config);
    }
    setState(() {});
  }

  Future<void> _submit() async {
    await widget.controller.submit(
      baseUrl: _baseUrl.text,
      apiKey: _apiKey.text,
      actor: _actor.text,
    );
  }

  Future<void> _signIn() async {
    final baseUrl = _baseUrl.text.trim();
    // Web has no loopback listener to bind — it uses the same-origin
    // reload flow instead (see OidcSignInController.startWebSignIn).
    if (kIsWeb) {
      await widget.oidcController?.startWebSignIn(
        baseUrl: baseUrl,
        redirectUri: Uri.base.origin,
      );
    } else {
      await widget.oidcController?.signInDesktop(baseUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to robot-notes')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: switch (_step) {
          _SetupStep.server => _buildServerStep(context),
          _SetupStep.login => _buildLoginStep(context),
        },
      ),
    );
  }

  Widget _buildServerStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('setup.baseUrl'),
          controller: _baseUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://notes.example',
          ),
        ),
        const SizedBox(height: 24),
        // Scoped to just the button so typing doesn't rebuild the whole
        // step — only the enabled state needs to track the field live.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _baseUrl,
          builder: (context, value, _) => FilledButton(
            key: const Key('setup.continue'),
            onPressed: isSecureBaseUrl(value.text) ? _continue : null,
            child: const Text('Continue'),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginStep(BuildContext context) {
    final state = widget.controller.value;
    final submitting = state is SetupSubmitting;
    final oidcState = widget.oidcController?.value;
    final signingIn = oidcState is OidcSignInInProgress;
    final showSignIn =
        widget.oidcController != null &&
        !_isMobilePlatform() &&
        _capabilities.supportsOidcLogin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _baseUrl.text.trim(),
                style: Theme.of(context).textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: const Key('setup.changeServer'),
              onPressed: _changeServer,
              child: const Text('Change server'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (state is SetupFailed) _ErrorBanner(message: state.message),
        if (oidcState is OidcSignInFailed)
          _ErrorBanner(message: oidcState.message),
        if (showSignIn) ...[
          FilledButton(
            key: const Key('setup.signInWithOidc'),
            onPressed: signingIn ? null : _signIn,
            child: signingIn
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Sign in with your identity provider'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Or enter an API key manually:',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('setup.apiKey'),
          controller: _apiKey,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'API key'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('setup.actor'),
          controller: _actor,
          decoration: const InputDecoration(
            labelText: 'Display name',
            helperText: 'Sent as X-Actor on every request.',
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('setup.submit'),
          onPressed: submitting ? null : _submit,
          child: submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }
}
