import 'package:flutter_web_plugins/url_strategy.dart';

/// Keeps web URLs as `/notes/<id>` instead of `/#/notes/<id>` so they can be
/// bookmarked and shared.
void configureUrlStrategy() {
  usePathUrlStrategy();
}
