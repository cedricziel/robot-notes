import 'package:flutter/foundation.dart';

/// No-op on every platform except web. Native desktop/mobile builds rely on
/// [CallbackShortcuts] instead, where `HardwareKeyboard` tracks modifier
/// keys correctly.
VoidCallback installWebSaveShortcut(VoidCallback onSave) => () {};
