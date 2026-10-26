/// MCP `system_*` tool handlers (docs/spec/mcp-tools.md §3.3).
///
/// Two-layer error model (§5): protocol errors stay in JSON-RPC; tool
/// execution failures return `CallToolResult(isError: true)` whose content
/// and structuredContent carry `{error: {code, message, hint?, source?}}`.
///
/// Declarative metadata (title/description/schemas/annotations) lives in the
/// single registry lib/mcp/tool_catalog.dart (ADR-0001); this module only
/// binds handlers to entries via [registerCatalogTool].
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/errors.dart';
import '../../services/system_parser.dart';
import '../../services/system_service.dart';

CallToolResult _toolErrorResult(Map<String, Object?> wire) => CallToolResult(
  content: [TextContent(text: jsonEncode(wire))],
  isError: true,
  structuredContent: wire,
);

CallToolResult _mapFailure(Object error) {
  if (error is GcmException) return _toolErrorResult(error.toWire());
  return _toolErrorResult(
    GcmException(GcmErrorCode.internal, '未预期的内部错误', cause: error).toWire(),
  );
}

/// Wraps a service call into a [CallToolResult], applying the tool-error
/// layer of the two-layer error model. The success path returns a
/// human-readable one-line summary as content (review P1: no auto-filled
/// JSON dump) plus the data as structuredContent. Also imported by the
/// network/mount/compose domains — keep this signature stable for them.
Future<CallToolResult> guardToolCall(
  Future<({Map<String, Object?> data, String summary})> Function() body,
) async {
  try {
    final (:data, :summary) = await body();
    return CallToolResult(
      content: [TextContent(text: summary)],
      structuredContent: data,
    );
  } catch (e) {
    return _mapFailure(e);
  }
}

String _versionText(RuntimeVersion? v) => v?.toString() ?? '-';

/// Registers the system domain tools on [service].
void registerSystemTools(ToolRegistrar service, SystemService systemService) {
  registerCatalogTool(
    service,
    'system_status',
    callback: (args, extra) => guardToolCall(() async {
      final info = await systemService.status();
      return (
        data: info.toJson(),
        summary:
            '运行时级别 ${info.readiness.level.name}（ready=${info.readiness.ready}，'
            'versionSupported=${info.readiness.versionSupported}）；'
            'CLI ${_versionText(info.readiness.cliVersion)} / '
            'apiserver ${_versionText(info.readiness.apiServerVersion)}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'system_start',
    callback: (args, extra) => guardToolCall(() async {
      final installKernel = args['installKernel'] as bool? ?? true;
      final result = await systemService.start(installKernel: installKernel);
      final kernelNote = switch (result.kernelInstalled) {
        true => '，内核已安装',
        false => '，内核仍未安装',
        null => '',
      };
      return (
        data: result.toJson(),
        summary:
            '运行时已启动（耗时 ${result.startupMs} ms$kernelNote，'
            '就绪级别 ${result.readiness.level.name}）',
      );
    }),
  );

  registerCatalogTool(
    service,
    'system_stop',
    callback: (args, extra) => guardToolCall(() async {
      final result = await systemService.stop();
      return (
        data: result.toJson(),
        summary: '运行时已停止（连带停止 ${result.containersStopped} 个运行中容器）',
      );
    }),
  );
}
