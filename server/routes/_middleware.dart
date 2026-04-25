import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/auth_middleware.dart';
import 'package:server/src/config.dart';
import 'package:server/src/config_holder.dart' as config_holder;

/// Root route middleware applied to every request.
///
/// Order is bottom-up: [provider] runs first so handlers can `read<Config>()`,
/// then [bearerAuth] gates traffic on the configured API key (with
/// `GET /healthz` exempted by the middleware itself).
Handler middleware(Handler handler) {
  final config = config_holder.config;
  return handler
      .use(bearerAuth(configuredKey: config.apiKey))
      .use(provider<Config>((_) => config));
}
