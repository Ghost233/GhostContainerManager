/// MCP `system_*` tool definitions (docs/spec/mcp-tools.md §3.3).
///
/// Two-layer error model (§5): protocol errors stay in JSON-RPC; tool
/// execution failures return `CallToolResult(isError: true)` whose content
/// and structuredContent carry `{error: {code, message, hint?, source?}}`.
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

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

const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

String _versionText(RuntimeVersion? v) => v?.toString() ?? '-';

/// Registers the system domain tools on [server].
void registerSystemTools(McpServer server, SystemService systemService) {
  server.registerTool(
    'system_status',
    title: '运行时状态',
    description:
        '返回 Apple container 运行时状态：五级就绪级别（未安装/版本低/主版本不兼容/'
        '服务未起/内核缺失/就绪）、CLI 与 apiserver 版本、版本是否受支持、'
        '服务状态与资源计数。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'level': const JsonString(
          description: '就绪级别',
          enumValues: [
            'notInstalled',
            'versionTooLow',
            'unsupportedMajor',
            'serviceNotRunning',
            'kernelMissing',
            'ready',
          ],
        ),
        'ready': const JsonBoolean(),
        'versionSupported': const JsonBoolean(
          description: '运行时版本是否通过基线（≥1.6.0）与大版本（1.x）门槛',
        ),
        'cliVersion': const JsonString(),
        'apiServerVersion': const JsonString(),
        'installPath': const JsonString(),
        'detail': const JsonString(),
        'debugBypass': const JsonBoolean(),
        'status': const JsonString(description: 'apiserver 状态，如 running'),
        'appRoot': const JsonString(),
        'installRoot': const JsonString(),
        'resources': const JsonObject(),
      },
      required: ['level', 'ready', 'versionSupported'],
    ),
    annotations: _readOnly,
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

  server.registerTool(
    'system_start',
    title: '启动运行时',
    description:
        '启动 Apple container 运行时（container system start，内核安装标志始终显式传递），'
        '随后轮询健康检查直到 apiserver 应答，并返回最新就绪级别。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'installKernel': JsonBoolean(
          description: '是否同时安装/更新默认内核（对应 --enable-kernel-install）',
          defaultValue: true,
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'status': const JsonString(description: '启动后守护进程状态，如 running'),
        'kernelInstalled': const JsonBoolean(
          description: '请求安装内核时的安装结果；installKernel=false 时不返回',
        ),
        'startupMs': const JsonInteger(
          description: '从 CLI 调用到 apiserver 应答的耗时（毫秒）',
        ),
        'level': const JsonString(),
        'ready': const JsonBoolean(),
        'detail': const JsonString(),
      },
      required: ['status', 'level', 'ready'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    ),
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

  server.registerTool(
    'system_stop',
    title: '停止运行时',
    description:
        '停止 Apple container 运行时（container system stop），'
        '运行中的容器随守护进程一并停止。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'status': const JsonString(description: '停止后守护进程状态，如 stopped'),
        'containersStopped': const JsonInteger(
          description: '随停止一并停下的运行中容器数（尽力统计）',
        ),
      },
      required: ['status', 'containersStopped'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: true,
      openWorldHint: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final result = await systemService.stop();
      return (
        data: result.toJson(),
        summary: '运行时已停止（连带停止 ${result.containersStopped} 个运行中容器）',
      );
    }),
  );
}
