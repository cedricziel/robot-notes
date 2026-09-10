import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/app_deps_holder.dart' as app_deps_holder;
import 'package:server/src/mcp/mcp_auth_middleware.dart';
import 'package:server/src/mcp/mcp_handler.dart';
import 'package:server/src/mcp/tools.dart';
import 'package:shared/shared.dart';

/// `/mcp`-scoped middleware: provides the [McpHandler] and gates every
/// request with [mcpAuth], which also provides the `McpPrincipal` the
/// route reads.
///
/// Built lazily on first request, mirroring `routes/_middleware.dart`:
/// the dart_frog generated entrypoint calls `buildRootHandler()` before
/// `entrypoint.run()` populates the [app_deps_holder] holder.
Handler middleware(Handler handler) {
  Handler? chain;
  return (context) async {
    chain ??= () {
      final deps = app_deps_holder.appDeps;
      return handler.use(mcpAuth()).use(
            provider<McpHandler>(
              (_) => McpHandler(
                tools: McpToolRegistry.forDeps(deps),
                serverVersion: robotNotesVersion,
              ),
            ),
          );
    }();
    return chain!(context);
  };
}
