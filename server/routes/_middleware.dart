import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/app_deps_holder.dart' as app_deps_holder;
import 'package:server/src/config_holder.dart' as config_holder;
import 'package:server/src/otel/otel_tracer_holder.dart' as otel_tracer_holder;
import 'package:server/src/root_middleware.dart';

/// Applies root middleware after server bootstrap installs dependencies.
Handler middleware(Handler handler) {
  Handler? chain;
  return (context) async {
    // Generated router builds before entrypoint installs dependency holders.
    chain ??= applyRootMiddleware(
      handler,
      deps: app_deps_holder.appDeps,
      config: config_holder.config,
      tracerProvider: otel_tracer_holder.otelTracerProvider,
    );
    return chain!(context);
  };
}
