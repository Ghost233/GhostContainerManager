/// MCP `container_*` read tools (docs/spec/mcp-tools.md 容器域, T2a).
///
/// Every result carries structuredContent AND a Chinese text summary.
/// Two-layer error model: tool failures come back as
/// `CallToolResult(isError: true)` with `{error: {code, message, hint?}}`.
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../services/errors.dart';

/// Like `guardToolCall` (system_tools.dart) but the success path also
/// emits a human-readable [summary] as text content.
Future<CallToolResult> _guardContainerCall(
  Future<({Map<String, Object?> data, String summary})> Function() body,
) async {
  try {
    final result = await body();
    return CallToolResult(
      content: [TextContent(text: result.summary)],
      structuredContent: result.data,
    );
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

/// Container tools read an external runtime — open world per the spec's
/// annotation contract.
const _readOnlyOpenWorld = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: true,
);

Map<String, Object?> _containerSummaryJson(ContainerSnapshotInfo c) {
  return <String, Object?>{
    'id': c.id,
    // apple/container has no separate display name — id is the name.
    'name': c.id,
    'image': c.image,
    'status': c.state.wireName,
    'labels': c.labels,
    'createdAt': c.createdAt?.toIso8601String(),
    'networks': c.networks
        .map(
          (n) => <String, Object?>{
            'name': n.network,
            'ip': n.address,
            'hostname': n.hostname,
          },
        )
        .toList(growable: false),
  };
}

/// Registers the container read tools on [server].
///
/// Logs stay UI-only (#13 decision): no `container_logs` tool here.
void registerContainerTools(McpServer server, ContainerService service) {
  server.registerTool(
    'container_list',
    title: '列出容器',
    description:
        '列出 Apple container 容器（id/镜像/状态/标签/网络）。'
        'label 参数为精确 key=value 过滤（如 com.ghost233.compose.project=web）；'
        'all=false 时只返回运行中的容器。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'all': const JsonBoolean(description: '是否包含已停止的容器', defaultValue: true),
        'label': const JsonString(description: '精确标签过滤，格式 key=value'),
        'status': const JsonString(
          description: '按生命周期状态过滤',
          enumValues: ['unknown', 'stopped', 'running', 'stopping'],
        ),
      },
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'containers': JsonArray(
          items: JsonObject(
            properties: <String, JsonSchema>{
              'id': const JsonString(),
              'name': const JsonString(),
              'image': const JsonString(),
              'status': const JsonString(),
              'labels': const JsonObject(),
              'createdAt': const JsonString(),
              'networks': const JsonArray(),
            },
            required: ['id', 'name', 'image', 'status'],
          ),
        ),
      },
      required: ['containers'],
    ),
    annotations: _readOnlyOpenWorld,
    callback: (args, extra) => _guardContainerCall(() async {
      final statusArg = args['status'] as String?;
      final query = ContainerQuery(
        includeStopped: args['all'] != false,
        label: args['label'] as String?,
        state: statusArg == null ? null : ContainerState.fromWire(statusArg),
      );
      final containers = await service.listContainers(query);
      final jsonList = containers.map(_containerSummaryJson).toList();
      final running = containers
          .where((c) => c.state == ContainerState.running)
          .length;
      return (
        data: <String, Object?>{'containers': jsonList},
        summary:
            '共 ${containers.length} 个容器（运行中 $running 个）：'
            '${containers.map((c) => '${c.id}(${c.state.wireName})').join('、')}',
      );
    }),
  );

  server.registerTool(
    'container_inspect',
    title: '容器详情',
    description:
        '返回单个容器的完整详情：状态、镜像、标签、网络、入口命令、环境变量、'
        '端口映射、停止信号与原始 configuration。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{'container': const JsonObject()},
      required: ['container'],
    ),
    annotations: _readOnlyOpenWorld,
    callback: (args, extra) => _guardContainerCall(() async {
      final id = args['id'] as String;
      final c = await service.inspect(id);
      final detail = <String, Object?>{
        ..._containerSummaryJson(c),
        'startedAt': c.startedAt?.toIso8601String(),
        'initCommand': c.initCommand,
        'initArguments': c.initArguments,
        'environment': c.environment,
        'publishedPorts': c.publishedPorts
            .map(
              (p) => <String, Object?>{
                'hostAddress': p.hostAddress,
                'hostPort': p.hostPort,
                'containerPort': p.containerPort,
                'proto': p.proto,
              },
            )
            .toList(growable: false),
        'stopSignal': c.stopSignal,
        'configuration': c.rawConfiguration,
      };
      return (
        data: <String, Object?>{'container': detail},
        summary:
            '容器 ${c.id}：镜像 ${c.image}，状态 ${c.state.wireName}，'
            '网络 ${c.networks.map((n) => '${n.network}/${n.address}').join('、')}',
      );
    }),
  );

  server.registerTool(
    'container_stats',
    title: '容器资源快照',
    description:
        '返回单个运行中容器的一次性资源快照（内存/CPU 微秒/网络/块设备/进程数）。'
        '需要速率时请自行轮询本工具（建议 2 秒间隔）。容器未运行时返回 CONFLICT 错误。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'stats': JsonObject(
          properties: <String, JsonSchema>{
            'id': const JsonString(),
            'memoryUsageBytes': const JsonInteger(),
            'memoryLimitBytes': const JsonInteger(),
            'memoryUtilization': const JsonNumber(),
            'cpuUsageUsec': const JsonInteger(),
            'networkRxBytes': const JsonInteger(),
            'networkTxBytes': const JsonInteger(),
            'blockReadBytes': const JsonInteger(),
            'blockWriteBytes': const JsonInteger(),
            'numProcesses': const JsonInteger(),
          },
          required: ['id'],
        ),
      },
      required: ['stats'],
    ),
    annotations: _readOnlyOpenWorld,
    callback: (args, extra) => _guardContainerCall(() async {
      final id = args['id'] as String;
      final stats = await service.stats(id);
      final utilization = stats.memoryUtilization;
      // All counters are optional upstream — emit only the ones present so
      // the structured content validates against the output schema.
      final statsJson = <String, Object?>{'id': stats.id};
      final optional = <String, Object?>{
        'memoryUsageBytes': stats.memoryUsageBytes,
        'memoryLimitBytes': stats.memoryLimitBytes,
        'memoryUtilization': utilization,
        'cpuUsageUsec': stats.cpuUsageUsec,
        'networkRxBytes': stats.networkRxBytes,
        'networkTxBytes': stats.networkTxBytes,
        'blockReadBytes': stats.blockReadBytes,
        'blockWriteBytes': stats.blockWriteBytes,
        'numProcesses': stats.numProcesses,
      };
      for (final entry in optional.entries) {
        if (entry.value != null) statsJson[entry.key] = entry.value;
      }
      return (
        data: <String, Object?>{'stats': statsJson},
        summary:
            '容器 ${stats.id}：内存 ${_mb(stats.memoryUsageBytes)}/'
            '${_mb(stats.memoryLimitBytes)}'
            '${utilization != null ? '（${(utilization * 100).toStringAsFixed(1)}%）' : ''}，'
            '进程 ${stats.numProcesses ?? '-'} 个',
      );
    }),
  );
}

String _mb(int? bytes) {
  if (bytes == null) return '-';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)}MB';
}
