import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: RobotNotesApp()));
}

/// Root widget for the robot-notes Flutter client.
///
/// At this point in the MVP buildout the app is a placeholder shell —
/// the setup screen, notes list, and editor land in sections 20–25
/// of `add-mvp-foundation`.
class RobotNotesApp extends StatelessWidget {
  const RobotNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'robot-notes',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const _PlaceholderHome(),
    );
  }
}

class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('robot-notes')),
      body: const Center(
        child: Text('robot-notes app scaffold (MVP build in progress)'),
      ),
    );
  }
}
