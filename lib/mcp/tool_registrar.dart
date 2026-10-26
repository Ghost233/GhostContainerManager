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

/// Definition snapshot captured at [ToolRegistrar.registerTool] time
/// (issue #29 验收 4)：schema/描述/注解不再被注册表丢弃，gcm_help 渲染与
/// gcm_call 分发前校验都以这份快照为准，与 lib/mcp/tool_catalog.dart 的
/// 声明式注册表之间不存在第二份手工拷贝（registerCatalogTool 透传条目
/// 对象本身）。
class ToolDefinitionSnapshot {
  const ToolDefinitionSnapshot({
    required this.name,
    this.title,
    this.description,
    this.inputSchema,
    this.outputSchema,
    this.annotations,
    this.meta,
    required this.callback,
  });

  final String name;
  final String? title;
  final String? description;
  final ToolInputSchema? inputSchema;
  final ToolOutputSchema? outputSchema;
  final ToolAnnotations? annotations;
  final Map<String, dynamic>? meta;
  final ToolFunction callback;
}

/// Collects tool definitions by name instead of registering them on the
/// protocol surface. Used by the slim MCP surface (`gcm_call` dispatches
/// through this table, `gcm_help` renders its membership).
class ToolCallbackRegistry implements ToolRegistrar {
  /// 注册时的定义快照（name → definition）；插入序即注册序。
  final Map<String, ToolDefinitionSnapshot> tools =
      <String, ToolDefinitionSnapshot>{};

  /// Derived view kept for call sites that only need the dispatch table.
  /// Writes must go through [registerTool] so the snapshot stays complete.
  Map<String, ToolFunction> get callbacks => <String, ToolFunction>{
    for (final tool in tools.values) tool.name: tool.callback,
  };

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
    tools[name] = ToolDefinitionSnapshot(
      name: name,
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
