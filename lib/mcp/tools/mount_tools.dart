/// MCP `mount_*` tools (docs/spec/mcp-tools.md §3.4) — read-only mount
/// aggregation. Apple container has no volume primitive; mounts are
/// container config aggregated by host source path.
library;

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/errors.dart';
import '../../services/mount_service.dart';
import 'system_tools.dart';

const _readOnly = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

/// Registers the mount domain tools on [server].
void registerMountTools(McpServer server, MountService mountService) {
  server.registerTool(
    'mount_list',
    title: 'List Mounts',
    description:
        '聚合所有容器（含已停止）的挂载配置，按主机源路径归组。'
        '每个挂载给出类型（virtiofs/tmpfs）、主机路径与使用它的容器及容器内目标路径。',
    inputSchema: const JsonObject(properties: {}, additionalProperties: false),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'mounts': const JsonArray()},
      required: ['mounts'],
    ),
    annotations: _readOnly,
    callback: (args, extra) => guardToolCall(() async {
      final mounts = await mountService.listMounts();
      final used = mounts.fold<int>(0, (sum, m) => sum + m.usedBy.length);
      return (
        data: <String, Object?>{
          'mounts': mounts.map((m) => m.toWire()).toList(growable: false),
        },
        summary: '共 ${mounts.length} 个挂载源，被引用 $used 次。',
      );
    }),
  );

  server.registerTool(
    'mount_inspect',
    title: 'Inspect Mount',
    description:
        '查看单个挂载的详情（按 mount_list 返回的 name，即主机源路径'
        '或 tmpfs:<目标路径>）。',
    inputSchema: const JsonObject(
      properties: <String, JsonSchema>{
        'name': JsonString(description: '挂载名（主机源路径或 tmpfs:<目标路径>）'),
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
          'mount_inspect requires a non-empty "name" argument.',
        );
      }
      final mount = await mountService.inspectMount(name);
      return (
        data: mount.toWire(),
        summary:
            '挂载 ${mount.name}（${mount.type}）：'
            '${mount.usedBy.length} 个容器使用。',
      );
    }),
  );
}
