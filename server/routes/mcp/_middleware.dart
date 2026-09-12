import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/app_deps_holder.dart' as app_deps_holder;
import 'package:server/src/mcp/mcp_chain.dart';
import 'package:server/src/otel/otel_tracer_holder.dart' as otel_tracer_holder;

/// `/mcp`-scoped middleware: [mcpChain] wraps [handler] with the
/// `McpHandler` provider and the auth gate that provides `McpPrincipal`.
///
/// Built lazily on first request, mirroring `routes/_middleware.dart`:
/// the dart_frog generated entrypoint calls `buildRootHandler()` before
/// `entrypoint.run()` populates the [app_deps_holder]/tracer holders.
Handler middleware(Handler handler) {
  Handler? chain;
  return (context) async {
    chain ??= mcpChain(
      handler,
      deps: app_deps_holder.appDeps,
      tracer: otel_tracer_holder.otelTracerProvider.getTracer(
        name: 'robot-notes-server',
      ),
    );
    return chain!(context);
  };
}
