import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/app_deps.dart';
import 'package:server/src/mcp/mcp_auth_middleware.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';

/// Builds the `/mcp`-scoped handler chain: [handler] wrapped in [mcpAuth]
/// (which gates every request and provides the `McpPrincipal` the route
/// reads) and a provider for the [McpHandler] built from [deps].
///
/// Shared by `routes/mcp/_middleware.dart` (production) and the
/// integration test harness (`test/integration/_test_app.dart`) so the
/// two never drift — before this existed, `_test_app.dart` hand-rolled
/// its own copy of this composition, which meant the integration suite
/// never actually exercised `routes/mcp/_middleware.dart` itself.
Handler mcpChain(Handler handler, {required AppDeps deps}) {
  return handler.use(mcpAuth()).use(
        provider<McpHandler>(
          (_) => McpHandler(
            tools: McpToolRegistry.forDeps(deps),
            serverVersion: robotNotesVersion,
          ),
        ),
      );
}
