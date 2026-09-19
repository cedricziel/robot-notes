import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth/oidc_sign_in_controller.dart';
import '../auth/server_capabilities.dart';
import '../config/app_config.dart';
import '../widgets/status_strip.dart';
import 'setup_controller.dart';

/// First-run flow, split into two steps: pick a server, then log in.
/// Step 1 is just the server URL and a Continue button. Step 2 offers,
/// when the entered server advertises OIDC support, a "Sign in" option —
/// via a loopback redirect on desktop, a same-origin reload on web, or a
/// browser sheet (`ASWebAuthenticationSession`/Custom Tabs) on mobile —
/// plus manual API-key entry as the always-available fallback.
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

/// Whether the current platform is a mobile one (Android/iOS), which
/// signs in via a browser sheet ([OidcSignInController.signInMobile])
/// rather than desktop's loopback listener or web's same-origin reload.
/// Uses `defaultTargetPlatform` rather than `dart:io`'s `Platform` so this
/// check compiles for web.
bool _isMobilePlatform() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

enum _SetupStep { server, login }

/// Live outcome of pinging the entered server's `/healthz`, shown next to
/// the URL field so a typo or unreachable host surfaces before the user
/// reaches "Connect" rather than only after it fails.
enum _Reachability { idle, checking, ok, error }

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _actor;
  Timer? _capabilitiesDebounce;
  ServerCapabilities _capabilities = ServerCapabilities.none;
  _SetupStep _step = _SetupStep.server;
  _Reachability _reachability = _Reachability.idle;
  int _reachabilityGen = 0;
  int _capabilitiesGen = 0;

  /// Whether the manual API-key/display-name fields have been expanded via
  /// the "Use an API key instead" disclosure. Only consulted when sign-in
  /// is offered — otherwise manual entry is always shown, unconditionally.
  bool _manualEntryExpanded = false;

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
    _checkReachability();
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
    _capabilitiesDebounce = Timer(widget.capabilitiesDebounce, () {
      _checkCapabilities();
      _checkReachability();
    });
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

  /// Checks [_baseUrl]'s capabilities and updates [_capabilities]. Guarded
  /// by a generation counter (mirroring [_checkReachability]'s) so a slow
  /// response for a server the user has since typed past can't clobber the
  /// capabilities of whatever they changed the field to in the meantime —
  /// otherwise "Sign in" could show, and route [_signIn] into
  /// `signInMobile`/`signInDesktop`/`startWebSignIn`, using a stale
  /// server's OIDC support against the URL currently in the field.
  Future<void> _checkCapabilities() async {
    if (widget.oidcController == null) return;
    final baseUrl = _baseUrl.text.trim();
    if (baseUrl.isEmpty) return;
    final gen = ++_capabilitiesGen;
    final client = widget.capabilitiesClientFactory();
    final ServerCapabilities caps;
    try {
      caps = await fetchServerCapabilities(baseUrl, client: client);
    } finally {
      client.close();
    }
    if (!mounted || gen != _capabilitiesGen) return;
    setState(() => _capabilities = caps);
  }

  /// Pings `/healthz` and updates [_reachability]. Guarded by a generation
  /// counter (mirroring the note editor's heartbeat/autosave scheduling) so
  /// a slow response to a stale URL can't clobber a newer, already-settled
  /// result.
  Future<void> _checkReachability() async {
    final baseUrl = _baseUrl.text.trim();
    if (baseUrl.isEmpty || !isSecureBaseUrl(baseUrl)) {
      _reachabilityGen++;
      if (mounted) setState(() => _reachability = _Reachability.idle);
      return;
    }
    final gen = ++_reachabilityGen;
    if (mounted) setState(() => _reachability = _Reachability.checking);
    final client = widget.capabilitiesClientFactory();
    var result = _Reachability.error;
    try {
      final res = await client
          .get(Uri.parse('$baseUrl/healthz'))
          .timeout(const Duration(seconds: 10));
      result = res.statusCode == 200 ? _Reachability.ok : _Reachability.error;
    } on Object {
      result = _Reachability.error;
    } finally {
      client.close();
    }
    if (!mounted || gen != _reachabilityGen) return;
    setState(() => _reachability = result);
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
    // Mobile has neither a loopback listener nor a same-origin page to
    // reload — it uses a browser sheet instead (signInMobile).
    if (kIsWeb) {
      await widget.oidcController?.startWebSignIn(
        baseUrl: baseUrl,
        redirectUri: Uri.base.origin,
      );
    } else if (_isMobilePlatform()) {
      await widget.oidcController?.signInMobile(baseUrl);
    } else {
      await widget.oidcController?.signInDesktop(baseUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connect')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                  child: Column(
                    children: [
                      Text(
                        'robot-notes',
                        key: const Key('setup.productName'),
                        style: theme.textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Notes shared between you and your agents',
                        key: const Key('setup.tagline'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                Card(
                  key: const Key('setup.card'),
                  margin: const EdgeInsets.all(16),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: switch (_step) {
                      _SetupStep.server => _buildServerStep(context),
                      _SetupStep.login => _buildLoginStep(context),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReachabilityIndicator() {
    switch (_reachability) {
      case _Reachability.idle:
        return const SizedBox.shrink();
      case _Reachability.checking:
        return const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox(
            key: Key('setup.reachability.checking'),
            width: 16,
            height: 16,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
        );
      case _Reachability.ok:
        return Icon(
          Icons.check_circle,
          key: const Key('setup.reachability.ok'),
          color: Theme.of(context).colorScheme.primary,
        );
      case _Reachability.error:
        return Tooltip(
          message: 'Could not reach this server.',
          child: Icon(
            Icons.error_outline,
            key: const Key('setup.reachability.error'),
            color: Theme.of(context).colorScheme.error,
          ),
        );
    }
  }

  Widget _buildServerStep(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('setup.baseUrl'),
          controller: _baseUrl,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://notes.example',
            suffixIcon: _buildReachabilityIndicator(),
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
        widget.oidcController != null && _capabilities.supportsOidcLogin;
    // Sign-in is the primary path when it's offered; manual key entry is
    // tucked behind a disclosure instead of competing for equal attention.
    // With no sign-in option, manual entry is the only path and always
    // shown.
    final manualEntryVisible = !showSignIn || _manualEntryExpanded;

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
        if (state is SetupFailed) _errorStrip(state.message),
        if (oidcState is OidcSignInFailed) _errorStrip(oidcState.message),
        if (showSignIn) ...[
          FilledButton(
            key: const Key('setup.signInWithOidc'),
            onPressed: signingIn ? null : _signIn,
            child: signingIn
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : const Text('Sign in with your identity provider'),
          ),
          if (!manualEntryVisible)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('setup.useApiKey'),
                  onPressed: () => setState(() => _manualEntryExpanded = true),
                  child: const Text('Use an API key instead'),
                ),
              ),
            ),
        ],
        if (manualEntryVisible) ...[
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
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : const Text('Connect'),
          ),
        ],
      ],
    );
  }
}

/// Error strip shown at the top of the login step, with the same bottom
/// spacing the old card-local banner used.
Widget _errorStrip(String message) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: StatusStrip(
    message: message,
    tone: StatusTone.error,
    icon: Icons.error_outline,
    rounded: true,
  ),
);
