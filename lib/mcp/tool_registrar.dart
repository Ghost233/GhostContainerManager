/// Structural seam shared by [McpServer] and the catalog dispatcher so the
/// per-domain `register*Tools` functions can register their tools against
/// either a real MCP server or a name-keyed callback table (精简注册模式,
/// 2026-10-26 用户拍板：MCP 只暴露 gcm_help/gcm_call 两个工具，35 个业务
/// 工具经 gcm_call 按名分发）。
library;

import 'package:mcp_dart/mcp_dart.dart';

/// Anything that accepts `registerTool` calls with the exact mcp_dart
/// signature. [McpServer] satisfies this structurally; [ToolCallbackRegistry]
/// collects callbacks for dispatch instead of protocol registration.
abstract class ToolRegistrar {
  void registerTool(
    String name, {
    String? title,
    String? description,
    ToolInputSchema? inputSchema,
    ToolOutputSchema? outputSchema,
    ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required ToolFunction callback,
  });
}

/// Collects tool callbacks by name instead of registering them on the
/// protocol surface. Used by the slim MCP surface (`gcm_call` dispatches
/// through this table).
class ToolCallbackRegistry implements ToolRegistrar {
  final Map<String, ToolFunction> callbacks = <String, ToolFunction>{};

  @override
  void registerTool(
    String name, {
    String? title,
    String? description,
    ToolInputSchema? inputSchema,
    ToolOutputSchema? outputSchema,
    ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required ToolFunction callback,
  }) {
    callbacks[name] = callback;
  }
}

/// Lets a real [McpServer] be passed where a [ToolRegistrar] is expected.
class McpServerRegistrar implements ToolRegistrar {
  McpServerRegistrar(this._server);

  final McpServer _server;

  @override
  void registerTool(
    String name, {
    String? title,
    String? description,
    ToolInputSchema? inputSchema,
    ToolOutputSchema? outputSchema,
    ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required ToolFunction callback,
  }) {
    _server.registerTool(
      name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations,
      meta: meta,
      callback: callback,
    );
  }
}
