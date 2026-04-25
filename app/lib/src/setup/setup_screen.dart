import 'package:flutter/material.dart';

import '../config/app_config.dart';
import 'setup_controller.dart';

/// First-run flow. Three text fields + a submit button. Renders the
/// controller state directly: error banner on [SetupFailed], spinner on
/// [SetupSubmitting], and on [SetupSuccess] hands the validated config back
/// to [onConfigured] so the parent can route to the notes list.
///
/// The controller is injected (rather than read from Riverpod) so widget
/// tests can drive a deterministic, mocked-http instance.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    required this.controller,
    required this.onConfigured,
    super.key,
  });

  final SetupController controller;
  final ValueChanged<AppConfig> onConfigured;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _actor;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController();
    _apiKey = TextEditingController();
    _actor = TextEditingController();
    widget.controller.addListener(_onState);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onState);
    _baseUrl.dispose();
    _apiKey.dispose();
    _actor.dispose();
    super.dispose();
  }

  void _onState() {
    final s = widget.controller.value;
    if (s is SetupSuccess) {
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

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final submitting = state is SetupSubmitting;

    return Scaffold(
      appBar: AppBar(title: const Text('Connect to robot-notes')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state is SetupFailed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      state.message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
            TextField(
              key: const Key('setup.baseUrl'),
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://notes.example',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('setup.apiKey'),
              controller: _apiKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API key',
              ),
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
        ),
      ),
    );
  }
}
