/// MCP `container_*` read/write tool handlers (docs/spec/mcp-tools.md 容器域).
///
/// Every result carries structuredContent AND a Chinese text summary.
/// Business failures use the shared two-layer guard in system_tools.dart.
/// Declarative metadata lives in lib/mcp/tool_catalog.dart (ADR-0001);
/// this module only binds handlers to registry entries.
library;

import '../tool_catalog.dart';
import '../tool_registrar.dart';

import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../services/errors.dart';
import 'pagination.dart';
import 'system_tools.dart';

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

/// Registers the container read tools on [service].
///
/// Logs stay UI-only (#13 decision): no `container_logs` tool here.
void registerContainerTools(
  ToolRegistrar service,
  ContainerService containerService,
) {
  registerCatalogTool(
    service,
    'container_list',
    callback: (args, extra) => guardToolCall(() async {
      final statusArg = args['status'] as String?;
      final query = ContainerQuery(
        includeStopped: args['all'] != false,
        label: args['label'] as String?,
        state: statusArg == null ? null : ContainerState.fromWire(statusArg),
      );
      final containers = await containerService.listContainers(query);
      // issue #31：稳定排序（id 即 name，升序）后统一分页。
      final sorted = List.of(containers)..sort((a, b) => a.id.compareTo(b.id));
      final running = sorted
          .where((c) => c.state == ContainerState.running)
          .length;
      final page = listPageArguments(args);
      final slice = listPageSlice(
        sorted,
        limit: page.limit,
        offset: page.offset,
      );
      return (
        data: <String, Object?>{
          'containers': slice
              .map(_containerSummaryJson)
              .toList(growable: false),
          ...listPageEnvelope(
            total: sorted.length,
            returned: slice.length,
            offset: page.offset,
          ),
        },
        summary:
            '共 ${sorted.length} 个容器（运行中 $running 个），本页 ${slice.length} 个'
            '${listSummaryPreview(slice.map((c) => '${c.id}(${c.state.wireName})'))}',
      );
    }),
  );

  registerCatalogTool(
    service,
    'container_inspect',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      final c = await containerService.inspect(id);
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

  registerCatalogTool(
    service,
    'container_stats',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      final stats = await containerService.stats(id);
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

  registerCatalogTool(
    service,
    'container_create',
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
      final id = await containerService.create(
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

  registerCatalogTool(
    service,
    'container_start',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      await containerService.start(id);
      return (
        data: <String, Object?>{'id': id, 'status': 'running'},
        summary: '容器 $id 已启动',
      );
    }),
  );

  registerCatalogTool(
    service,
    'container_stop',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      final timeout = args['timeoutSeconds'] as int? ?? 5;
      final stoppedGracefully = await containerService.stop(
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

  registerCatalogTool(
    service,
    'container_restart',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      await containerService.restart(
        id,
        timeoutSeconds: args['timeoutSeconds'] as int? ?? 5,
      );
      return (
        data: <String, Object?>{'id': id, 'status': 'running'},
        summary: '容器 $id 已重启',
      );
    }),
  );

  registerCatalogTool(
    service,
    'container_kill',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      final signal = args['signal'] as String? ?? 'KILL';
      final status = await containerService.kill(id, signal: signal);
      return (
        data: <String, Object?>{'id': id, 'signal': signal, 'status': status},
        summary: '已向容器 $id 发送 $signal 信号',
      );
    }),
  );

  registerCatalogTool(
    service,
    'container_delete',
    callback: (args, extra) => guardToolCall(() async {
      final id = args['id'] as String;
      await containerService.delete(id, force: args['force'] == true);
      return (
        data: <String, Object?>{'id': id, 'deleted': true},
        summary: '容器 $id 已删除',
      );
    }),
  );

  registerCatalogTool(
    service,
    'container_exec',
    callback: (args, extra) => guardToolCall(() async {
      // issue #30：分发前 schema 校验只保证 id 存在，不剔除首尾空白；
      // 这里统一 trim，缺失时退为空串由服务层按 NOT_FOUND 处理。
      final id = (args['id'] as String?)?.trim() ?? '';
      final ContainerExecResult result;
      try {
        result = await containerService.exec(
          id,
          command: (args['command'] as List).cast<String>(),
          // 默认 60s 与 docs/spec/mcp-tools.md §3.1、container-lifecycle.md
          // §3 一致；lifecycle §2 矩阵曾写 30（漂移，由 #32 回报给 Lead 改
          // 文档），代码侧统一为 60。
          timeoutSeconds: args['timeoutSeconds'] as int? ?? 60,
          workdir: args['workdir'] as String?,
          env:
              (args['env'] as Map?)?.map(
                (key, value) => MapEntry(key as String, value as String),
              ) ??
              const <String, String>{},
        );
      } on GcmException catch (e) {
        // issue #32 长任务核对：超时 = 放弃等待，进程可能仍在容器内运行
        // （上游 apple/container#1941，exec 进程无可靠 kill 路由）。补全
        // 查询途径：资源标识在 message 里（容器 id），查询方法在此补进
        // hint——不得让 agent 把超时读成「进程已停止」。
        if (e.code == GcmErrorCode.timeout) {
          throw GcmException(
            GcmErrorCode.timeout,
            e.message,
            hint:
                '进程可能仍在容器内运行（放弃等待≠已停止）；'
                '用 container_inspect 查容器状态，或重试 container_exec 探活。',
            source: e.source,
            cause: e.cause,
          );
        }
        rethrow;
      }
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
