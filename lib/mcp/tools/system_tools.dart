/// MCP `system_*` tool definitions (docs/spec/mcp-tools.md §3.3).
///
/// Two-layer error model (§5): protocol errors stay in JSON-RPC; tool
/// execution failures return `CallToolResult(isError: true)` whose content
/// and structuredContent carry `{error: {code, message, hint?}}`.
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/errors.dart';
import '../../services/system_service.dart';

/// Wraps a service call into a [CallToolResult], applying the tool-error
/// layer of the two-layer error model.
Future<CallToolResult> guardToolCall(
  Future<Map<String, Object?>> Function() body,
) async {
  try {
    return CallToolResult.fromStructuredContent(await body());
  } on GcmException catch (e) {
    final wire = e.toWire();
    return CallToolResult(
      content: [TextContent(text: jsonEncode(wire))],
      isError: true,
      structuredContent: wire,
    );
  } catch (e) {
    final wire = GcmException(
      GcmErrorCode.internal,
      '未预期的内部错误',
      cause: e,
    ).toWire();
    return CallToolResult(
      content: [TextContent(text: jsonEncode(wire))],
      isError: true,
      structuredContent: wire,
    );
  }
}

const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

/// Registers the system domain tools on [server].
void registerSystemTools(McpServer server, SystemService systemService) {
  server.registerTool(
    'system_status',
    title: '运行时状态',
    description:
        '返回 Apple container 运行时状态：五级就绪级别（未安装/版本低/主版本不兼容/'
        '服务未起/内核缺失/就绪）、CLI 与 apiserver 版本、服务状态与资源计数。',
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
      required: ['level', 'ready'],
    ),
    annotations: _readOnly,
    callback: (args, extra) =>
        guardToolCall(() async => (await systemService.status()).toJson()),
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
          defaultValue: false,
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'level': const JsonString(),
        'ready': const JsonBoolean(),
        'detail': const JsonString(),
      },
      required: ['level', 'ready'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final installKernel = args['installKernel'] == true;
      return (await systemService.start(installKernel: installKernel)).toJson();
    }),
  );

  server.registerTool(
    'system_stop',
    title: '停止运行时',
    description: '停止 Apple container 运行时（container system stop）。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'stopped': const JsonBoolean()},
      required: ['stopped'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: true,
      openWorldHint: true,
    ),
    callback: (args, extra) => guardToolCall(() async {
      await systemService.stop();
      return <String, Object?>{'stopped': true};
    }),
  );
}
