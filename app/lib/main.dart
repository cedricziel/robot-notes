import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'src/app_router.dart';
import 'src/config/config_store.dart';
import 'src/url_strategy.dart';

export 'src/app_router.dart' show NoteRoute, blankNoteTitle, createBlankNote;

void main() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Web leaves the semantics tree off until the user finds a hidden
  // enable-accessibility control; native platforms turn it on themselves.
  if (kIsWeb) binding.ensureSemantics();
  configureUrlStrategy();
  runApp(const RobotNotesApp());
}

/// Root widget for the robot-notes Flutter client. Owns the [GoRouter] and
/// the [ConfigHolder] that drives its first-run redirect for the app's
/// entire lifetime.
class RobotNotesApp extends StatefulWidget {
  const RobotNotesApp({super.key});

  @override
  State<RobotNotesApp> createState() => _RobotNotesAppState();
}

class _RobotNotesAppState extends State<RobotNotesApp> {
  final ConfigStore _store = SecureConfigStore();
  late final ConfigHolder _configHolder = ConfigHolder(_store);
  late final GoRouter _router = buildAppRouter(configHolder: _configHolder);

  @override
  void dispose() {
    _configHolder.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'robot-notes',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      routerConfig: _router,
      builder: (context, child) =>
          AppRouterShell(configHolder: _configHolder, child: child),
    );
  }
}
