/// MCP `network_*` tools (docs/spec/mcp-tools.md §3.4) — read-only network
/// listing via CLI (`container network ls --format json`) joined with
/// container snapshot attachments.
library;

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/errors.dart';
import '../../services/network_service.dart';
import 'system_tools.dart';

const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

/// Registers the network domain tools on [server].
void registerNetworkTools(McpServer server, NetworkService networkService) {
  server.registerTool(
    'network_list',
    title: '网络列表',
    description: '列出所有 container 网络（名称、子网、模式、是否内建、当前接入的容器数）。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'networks': const JsonArray()},
      required: ['networks'],
    ),
    annotations: _readOnly,
    callback: (args, extra) => guardToolCall(() async {
      final networks = await networkService.listNetworks();
      return (
        data: <String, Object?>{
          'networks': networks.map((n) => n.toWire()).toList(growable: false),
        },
        summary: '共 ${networks.length} 个网络。',
      );
    }),
  );

  server.registerTool(
    'network_get',
    title: '网络详情',
    description:
        '查看单个网络的详情与接入的容器（id、IP、hostname）。'
        '参数 name 为 network_list 返回的网络名。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'name': JsonString(description: '网络名（如 default）'),
      },
      required: ['name'],
      additionalProperties: false,
    ),
    annotations: _readOnly,
    callback: (args, extra) => guardToolCall(() async {
      final name = args['name'];
      if (name is! String || name.isEmpty) {
        throw const GcmException(
          GcmErrorCode.invalidArgument,
          'network_get requires a non-empty "name" argument.',
        );
      }
      final detail = await networkService.getNetwork(name);
      return (
        data: detail.toWire(),
        summary: '网络 ${detail.info.id}：${detail.containers.length} 个容器接入。',
      );
    }),
  );
}
