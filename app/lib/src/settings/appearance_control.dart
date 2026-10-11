import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/adaptive.dart';
import 'app_preferences.dart';

/// Selects and persists the device appearance using platform controls.
class AppearanceControl extends StatelessWidget {
  const AppearanceControl({required this.preferences, super.key});

  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      if (useCupertino(context)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Appearance', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            CupertinoSlidingSegmentedControl<ThemeMode>(
              groupValue: preferences.themeMode,
              children: const {
                ThemeMode.system: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('System'),
                ),
                ThemeMode.light: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Light'),
                ),
                ThemeMode.dark: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Dark'),
                ),
              },
              onValueChanged: (mode) {
                if (mode != null) unawaited(preferences.setThemeMode(mode));
              },
            ),
          ],
        );
      }
      return DropdownButtonFormField<ThemeMode>(
        initialValue: preferences.themeMode,
        decoration: const InputDecoration(labelText: 'Appearance'),
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
        ],
        onChanged: (mode) {
          if (mode != null) unawaited(preferences.setThemeMode(mode));
        },
      );
    },
  );
}
