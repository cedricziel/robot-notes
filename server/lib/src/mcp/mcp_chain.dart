import 'package:dart_frog/dart_frog.dart';
import 'package:dart_otel_api/dart_otel_api.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/mcp/mcp_auth_middleware.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';

/// Builds the `/mcp`-scoped handler chain: [handler] wrapped in [mcpAuth]
/// (which gates every request and provides the `McpPrincipal` the route
/// reads) and a provider for the [McpHandler] built from [deps].
///
/// [tracer] is optional (defaulting to a no-op) rather than resolved from
/// the global `otel_tracer_holder` here, so this function stays free of
/// process-wide state: `test/integration/_test_app.dart` calls it directly
/// with hand-built [deps], deliberately bypassing every global holder so
/// parallel test servers don't share state — reaching into the tracer
/// holder from here would break that isolation and crash every
/// integration test (the holder is only ever populated by
/// `server/main.dart`). The production caller,
/// `routes/mcp/_middleware.dart`, resolves the tracer from the holder
/// itself and passes it in, the same way it already does for [deps].
///
/// Shared by `routes/mcp/_middleware.dart` (production) and the
/// integration test harness (`test/integration/_test_app.dart`) so the
/// two never drift — before this existed, `_test_app.dart` hand-rolled
/// its own copy of this composition, which meant the integration suite
/// never actually exercised `routes/mcp/_middleware.dart` itself.
Handler mcpChain(Handler handler, {required AppDeps deps, Tracer? tracer}) {
  return handler.use(mcpAuth()).use(
        provider<McpHandler>(
          (_) => McpHandler(
            tools: McpToolRegistry.forDeps(deps),
            serverVersion: robotNotesVersion,
            tracer: tracer,
          ),
        ),
      );
}
