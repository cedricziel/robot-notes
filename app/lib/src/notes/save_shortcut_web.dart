import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Installs a `keydown` listener directly on `window` that intercepts
/// Cmd+S (macOS) / Ctrl+S and calls [onSave], calling `preventDefault()` so
/// the browser's own "Save Page" action never fires.
///
/// Flutter web's `HardwareKeyboard` tracks modifier keys by watching for
/// their own keydown/keyup events, but browsers do not reliably deliver a
/// separate keydown for Meta/Control before a combo like this reaches the
/// page — only the letter key's event carries `metaKey`/`ctrlKey` — so
/// `HardwareKeyboard.instance.isMetaPressed` stays false and
/// `SingleActivator(meta: true)` inside `CallbackShortcuts` never matches.
/// Reading the flags directly off the raw browser event sidesteps that
/// tracking gap entirely.
///
/// Returns a callback that removes the listener.
VoidCallback installWebSaveShortcut(VoidCallback onSave) {
  void handler(web.Event event) {
    if (!event.isA<web.KeyboardEvent>()) return;
    final keyEvent = event as web.KeyboardEvent;
    if (keyEvent.code != 'KeyS') return;
    if (!keyEvent.metaKey && !keyEvent.ctrlKey) return;
    keyEvent.preventDefault();
    onSave();
  }

  final listener = handler.toJS;
  web.window.addEventListener('keydown', listener);
  return () => web.window.removeEventListener('keydown', listener);
}
