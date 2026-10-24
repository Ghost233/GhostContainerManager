/// MCP `container_*` read/write tools (docs/spec/mcp-tools.md 容器域).
///
/// Every result carries structuredContent AND a Chinese text summary.
/// Business failures use the shared two-layer guard in system_tools.dart.
library;

import 'package:mcp_dart/mcp_dart.dart';

import '../../services/container_models.dart';
import '../../services/container_service.dart';
import 'system_tools.dart';

ToolAnnotations _writeAnnotations(
  String title, {
  bool destructive = false,
  bool idempotent = true,
}) => ToolAnnotations(
  title: title,
  readOnlyHint: false,
  destructiveHint: destructive,
  idempotentHint: idempotent,
  openWorldHint: true,
);

/// Container tools read an external runtime — open world per the spec's
/// annotation contract.
ToolAnnotations _readOnlyOpenWorld(String title) => ToolAnnotations(
  title: title,
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
    title: 'List Containers',
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
    annotations: _readOnlyOpenWorld('List Containers'),
    callback: (args, extra) => guardToolCall(() async {
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
    title: 'Inspect Container',
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
    annotations: _readOnlyOpenWorld('Inspect Container'),
    callback: (args, extra) => guardToolCall(() async {
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
    title: 'Container Stats',
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
    annotations: _readOnlyOpenWorld('Container Stats'),
    callback: (args, extra) => guardToolCall(() async {
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

  server.registerTool(
    'container_create',
    title: 'Create Container',
    description:
        '从本地镜像创建容器，默认只创建不启动。镜像不存在时不会自动拉取；'
        'name 重名会返回 CONFLICT。env 是键值对象，ports 是 host/container 端口对象数组。'
        'mounts 定义主机目录挂载，labels 是字符串标签对象。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'name': const JsonString(description: '容器名称；省略时生成名称'),
        'image': const JsonString(description: '本地镜像引用，必填'),
        'command': const JsonArray(
          description: '覆盖镜像入口命令的参数数组',
          items: JsonString(),
        ),
        'env': const JsonObject(
          description: '环境变量键值对象，值会转换为 KEY=VALUE',
          additionalProperties: JsonString(),
        ),
        'ports': const JsonArray(
          description: '端口映射；proto 缺省为 tcp',
          items: JsonObject(
            properties: <String, JsonSchema>{
              'host': JsonInteger(minimum: 1, maximum: 65535),
              'container': JsonInteger(minimum: 1, maximum: 65535),
              'proto': JsonString(enumValues: ['tcp', 'udp']),
            },
            required: ['host', 'container'],
            additionalProperties: false,
          ),
        ),
        'network': const JsonString(description: '目标网络名称'),
        'mounts': const JsonArray(
          description: '主机目录挂载；target 必须是容器内绝对路径',
          items: JsonObject(
            properties: <String, JsonSchema>{
              'source': JsonString(description: '主机目录绝对路径'),
              'target': JsonString(description: '容器内挂载点绝对路径'),
              'readonly': JsonBoolean(
                description: '是否只读挂载',
                defaultValue: false,
              ),
            },
            required: ['source', 'target'],
            additionalProperties: false,
          ),
        ),
        'labels': const JsonObject(
          description: '容器标签；键和值均为字符串',
          additionalProperties: JsonString(),
        ),
        'start': const JsonBoolean(description: '创建后立即启动', defaultValue: false),
      },
      required: ['image'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'name': const JsonString(),
        'status': const JsonString(),
        'warnings': const JsonArray(items: JsonString()),
      },
      required: ['id', 'name', 'status', 'warnings'],
    ),
    annotations: _writeAnnotations('Create Container', idempotent: false),
    callback: (args, extra) => guardToolCall(() async {
      final environment = args['env'] == null
          ? const <String>[]
          : (args['env'] as Map).entries
                .map((entry) => '${entry.key}=${entry.value}')
                .toList(growable: false);
      final ports = (args['ports'] as List? ?? const <Object?>[])
          .map((raw) {
            final port = raw as Map;
            return '${port['host']}:${port['container']}/${port['proto'] ?? 'tcp'}';
          })
          .toList(growable: false);
      final mounts = (args['mounts'] as List? ?? const <Object?>[])
          .map((raw) => (raw as Map).cast<String, Object?>())
          .toList(growable: false);
      final labels =
          (args['labels'] as Map?)?.map(
            (key, value) => MapEntry(key as String, value as String),
          ) ??
          const <String, String>{};
      final start = args['start'] == true;
      final id = await service.create(
        id: args['name'] as String?,
        image: args['image'] as String,
        command: (args['command'] as List?)?.cast<String>() ?? const <String>[],
        env: environment,
        ports: ports,
        network: args['network'] as String?,
        mounts: mounts,
        labels: labels,
        start: start,
      );
      return (
        data: <String, Object?>{
          'id': id,
          'name': id,
          'status': start ? 'running' : 'stopped',
          'warnings': const <String>[],
        },
        summary: start ? '容器 $id 已创建并启动' : '容器 $id 已创建（未启动）',
      );
    }),
  );

  server.registerTool(
    'container_start',
    title: 'Start Container',
    description: '启动容器；已经处于 running 时幂等成功。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'status': const JsonString(),
      },
      required: ['id', 'status'],
    ),
    annotations: _writeAnnotations('Start Container'),
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      await service.start(id);
      return (
        data: <String, Object?>{'id': id, 'status': 'running'},
        summary: '容器 $id 已启动',
      );
    }),
  );

  server.registerTool(
    'container_stop',
    title: 'Stop Container',
    description:
        '优雅停止容器；默认等待 5 秒，超时由 runtime 发送 SIGKILL。'
        'stoppedGracefully 按已停止状态或停止调用是否短于 timeout 保守推导，'
        'runtime 不直接报告实际是否发生 SIGKILL 升级。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'timeoutSeconds': const JsonInteger(
          description: '优雅停止等待秒数，0 表示立即升级',
          defaultValue: 5,
          minimum: 0,
          maximum: 2147483647,
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'status': const JsonString(),
        'stoppedGracefully': const JsonBoolean(),
      },
      required: ['id', 'status', 'stoppedGracefully'],
    ),
    annotations: _writeAnnotations('Stop Container'),
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      final timeout = args['timeoutSeconds'] as int? ?? 5;
      final stoppedGracefully = await service.stop(
        id,
        timeoutSeconds: timeout,
      );
      return (
        data: <String, Object?>{
          'id': id,
          'status': 'stopped',
          'stoppedGracefully': stoppedGracefully,
        },
        summary: '容器 $id 已停止',
      );
    }),
  );

  server.registerTool(
    'container_restart',
    title: 'Restart Container',
    description: '按 stop 后 start 合成重启，非原子操作；停止超时时由 runtime 发送 SIGKILL。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'timeoutSeconds': const JsonInteger(
          description: '停止阶段的优雅等待秒数',
          defaultValue: 5,
          minimum: 0,
          maximum: 2147483647,
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'status': const JsonString(),
      },
      required: ['id', 'status'],
    ),
    annotations: _writeAnnotations('Restart Container'),
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      await service.restart(
        id,
        timeoutSeconds: args['timeoutSeconds'] as int? ?? 5,
      );
      return (
        data: <String, Object?>{'id': id, 'status': 'running'},
        summary: '容器 $id 已重启',
      );
    }),
  );

  server.registerTool(
    'container_kill',
    title: 'Kill Container',
    description: '向容器主进程发送信号；signal 默认 KILL，也可为 TERM、INT、HUP 等。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'signal': const JsonString(
          description: 'Unix 信号名称',
          defaultValue: 'KILL',
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'signal': const JsonString(),
        'status': const JsonString(),
      },
      required: ['id', 'signal', 'status'],
    ),
    annotations: _writeAnnotations('Kill Container', destructive: true),
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      final signal = args['signal'] as String? ?? 'KILL';
      await service.kill(id, signal: signal);
      return (
        data: <String, Object?>{'id': id, 'signal': signal},
        summary: '已向容器 $id 发送 $signal 信号',
      );
    }),
  );

  server.registerTool(
    'container_delete',
    title: 'Delete Container',
    description:
        '删除容器。running 容器必须显式 force=true；stopping 容器即使 force 也会返回 CONFLICT，'
        '必须等待停止完成。重复删除不存在的容器按幂等成功处理。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '容器 id'),
        'force': const JsonBoolean(
          description: '允许强制删除 running 容器，不绕过 stopping',
          defaultValue: false,
        ),
      },
      required: ['id'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(),
        'deleted': const JsonBoolean(),
      },
      required: ['id', 'deleted'],
    ),
    annotations: _writeAnnotations('Delete Container', destructive: true),
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      await service.delete(id, force: args['force'] == true);
      return (
        data: <String, Object?>{'id': id, 'deleted': true},
        summary: '容器 $id 已删除',
      );
    }),
  );

  server.registerTool(
    'container_exec',
    title: 'Execute Container Command',
    description:
        '在运行中的容器内执行一次性非 TTY 命令。command 为 argv 数组，不经过 shell；'
        '分别返回 stdout/stderr（各最多 64 KiB）、退出码与截断标记。'
        '非零退出码是命令结果而非工具错误。timeoutSeconds 默认 60，最大 600。',
    inputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'id': const JsonString(description: '运行中容器 id'),
        'command': const JsonArray(
          description: '可执行文件及参数的 argv 数组',
          items: JsonString(),
        ),
        'timeoutSeconds': const JsonInteger(
          description: '等待命令退出的秒数',
          defaultValue: 60,
          minimum: 1,
          maximum: 600,
        ),
        'workdir': const JsonString(description: '容器内工作目录'),
        'env': const JsonObject(
          description: '覆盖容器环境变量的键值对象',
          additionalProperties: JsonString(),
        ),
      },
      required: ['id', 'command'],
      additionalProperties: false,
    ),
    outputSchema: JsonObject(
      properties: <String, JsonSchema>{
        'exitCode': const JsonInteger(),
        'stdout': const JsonString(),
        'stderr': const JsonString(),
        'truncated': const JsonBoolean(),
      },
      required: ['exitCode', 'stdout', 'stderr', 'truncated'],
      additionalProperties: false,
    ),
    annotations: _writeAnnotations(
      'Execute Container Command',
      idempotent: false,
    ),
    callback: (args, extra) => guardToolCall(() async {
      final result = await service.exec(
        args['id'] as String,
        command: (args['command'] as List).cast<String>(),
        timeoutSeconds: args['timeoutSeconds'] as int? ?? 60,
        workdir: args['workdir'] as String?,
        env:
            (args['env'] as Map?)?.map(
              (key, value) => MapEntry(key as String, value as String),
            ) ??
            const <String, String>{},
      );
      return (
        data: result.toJson(),
        summary:
            '命令已结束，退出码 ${result.exitCode}'
            '${result.truncated ? '；输出已达 64 KiB 上限并截断' : ''}',
      );
    }),
  );
}

String _mb(int? bytes) {
  if (bytes == null) return '-';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)}MB';
}
