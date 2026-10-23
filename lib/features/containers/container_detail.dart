/// 容器检查器（ui-ia.md D2 A1）：标签页详情 = 概览 + 日志（实时滚动）。
///
/// 概览 = inspect 全量配置 + stats 快照（验收 #17 标准 2：CPU/内存等
/// XPC 可得字段可见）；日志 = XPC 双 FileHandle 流（stdio/boot），
/// UI 专属（MCP 无 logs 工具，#13 策展决策）。终端标签归后续写操作
/// 任务（#18/D3），本页不含。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/container_logs_parser.dart';
import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../services/errors.dart';
import 'containers_page.dart';

class ContainerDetailView extends StatelessWidget {
  const ContainerDetailView({
    super.key,
    required this.service,
    required this.containerId,
    required this.onBack,
  });

  final ContainerService service;
  final String containerId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('返回容器列表'),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    containerId,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: '概览'),
              Tab(text: '日志'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(service: service, containerId: containerId),
                ContainerLogTab(service: service, containerId: containerId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 概览：配置键值 + 资源占用（stats 单次快照；停止容器显示无实时统计）。
class _OverviewTab extends StatefulWidget {
  const _OverviewTab({required this.service, required this.containerId});

  final ContainerService service;
  final String containerId;

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  late final Future<ContainerSnapshotInfo> _detail = widget.service.inspect(
    widget.containerId,
  );
  late final Future<ContainerStatsInfo> _stats = widget.service.stats(
    widget.containerId,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ContainerSnapshotInfo>(
      future: _detail,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              '详情加载失败：${snapshot.error}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }
        final info = snapshot.data;
        if (info == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _StatsCard(statsFuture: _stats, state: info.state),
            const SizedBox(height: 24),
            _kv(context, '名称 / ID', info.id, mono: true),
            _kv(context, '镜像', info.image, mono: true),
            _kv(context, '状态', info.state.wireName),
            _kv(
              context,
              '创建时间',
              info.createdAt == null ? '—' : formatDateTime(info.createdAt!),
            ),
            _kv(
              context,
              '启动时间',
              info.startedAt == null ? '—' : formatDateTime(info.startedAt!),
            ),
            _kv(
              context,
              '入口命令',
              [
                info.initCommand,
                ...info.initArguments,
              ].where((s) => s.isNotEmpty).join(' '),
              mono: true,
            ),
            _kv(context, '停止信号', info.stopSignal, mono: true),
            for (final network in info.networks)
              _kv(
                context,
                '网络 ${network.network}',
                '${network.address.isEmpty ? '—' : network.address}'
                    '（网关 ${network.gateway.isEmpty ? '—' : network.gateway}）',
                mono: true,
              ),
            _kv(
              context,
              '端口映射',
              info.publishedPorts.isEmpty
                  ? '—'
                  : info.publishedPorts
                        .map(
                          (p) =>
                              '${p.hostAddress}:${p.hostPort}→'
                              '${p.containerPort}/${p.proto}',
                        )
                        .join('\n'),
              mono: true,
            ),
            _kv(
              context,
              '环境变量',
              info.environment.isEmpty ? '—' : info.environment.join('\n'),
              mono: true,
            ),
            _kv(
              context,
              '标签',
              info.labels.isEmpty
                  ? '—'
                  : info.labels.entries
                        .map((e) => '${e.key}=${e.value}')
                        .join('\n'),
              mono: true,
            ),
          ],
        );
      },
    );
  }

  Widget _kv(
    BuildContext context,
    String key,
    String value, {
    bool mono = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: mono ? monoTextStyle(context) : theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// stats 卡片：内存用量条 + CPU/进程/网络/块 IO 字段。
class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.statsFuture, required this.state});

  final Future<ContainerStatsInfo> statsFuture;
  final ContainerState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<ContainerStatsInfo>(
          future: statsFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              final stopped =
                  error is GcmException && error.code == GcmErrorCode.conflict;
              return Text(
                stopped ? '容器未在运行，无实时统计' : '统计加载失败：$error',
                style: theme.textTheme.bodySmall,
              );
            }
            final stats = snapshot.data;
            if (stats == null) {
              return Text('正在读取统计…', style: theme.textTheme.bodySmall);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('资源占用', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text(
                      '进程 ${stats.numProcesses ?? '—'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _memoryRow(context, stats),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _stat(
                      context,
                      'CPU 累计',
                      stats.cpuUsageUsec == null
                          ? '—'
                          : '${(stats.cpuUsageUsec! / 1000000).toStringAsFixed(2)} s',
                    ),
                    _stat(
                      context,
                      '网络接收',
                      stats.networkRxBytes == null
                          ? '—'
                          : formatBytes(stats.networkRxBytes!),
                    ),
                    _stat(
                      context,
                      '网络发送',
                      stats.networkTxBytes == null
                          ? '—'
                          : formatBytes(stats.networkTxBytes!),
                    ),
                    _stat(
                      context,
                      '块读 / 写',
                      '${stats.blockReadBytes == null ? '—' : formatBytes(stats.blockReadBytes!)}'
                          ' / ${stats.blockWriteBytes == null ? '—' : formatBytes(stats.blockWriteBytes!)}',
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _memoryRow(BuildContext context, ContainerStatsInfo stats) {
    final theme = Theme.of(context);
    final usage = stats.memoryUsageBytes;
    final limit = stats.memoryLimitBytes;
    final utilization = stats.memoryUtilization;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '内存 ${usage == null ? '—' : formatBytes(usage)}'
          ' / ${limit == null ? '—' : formatBytes(limit)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: utilization, minHeight: 4),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        Text(value, style: monoTextStyle(context)),
      ],
    );
  }
}

/// 日志标签页：stdio/boot 双源实时滚动；上滚暂停跟随，回到底部恢复。
class ContainerLogTab extends StatefulWidget {
  const ContainerLogTab({
    super.key,
    required this.service,
    required this.containerId,
  });

  final ContainerService service;
  final String containerId;

  @override
  State<ContainerLogTab> createState() => _ContainerLogTabState();
}

class _ContainerLogTabState extends State<ContainerLogTab>
    with AutomaticKeepAliveClientMixin {
  final List<Widget> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<ContainerLogEvent>? _sub;
  bool _follow = true;
  bool _ended = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sub = widget.service.logs(widget.containerId).listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onEvent(ContainerLogEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event.kind) {
        case 'data':
          final prefix = event.source == 'boot' ? '[boot] ' : '';
          for (final line in event.text.split('\n')) {
            if (line.isEmpty) continue;
            _lines.add(Text('$prefix$line', style: monoTextStyle(context)));
          }
        case 'error':
          _lines.add(
            Text(
              '日志流错误：${event.message}',
              style: monoTextStyle(context)
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          );
        case 'eof':
          _ended = true;
          _lines.add(
            Text(
              '— 日志流已结束 —',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          );
      }
    });
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final atBottom =
          notification.metrics.pixels >=
          notification.metrics.maxScrollExtent - 40;
      if (_follow != atBottom) {
        setState(() => _follow = atBottom);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          child: Text(
            'stdio / boot 双源 · 实时滚动${_ended ? ' · 已结束' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: _lines.isEmpty
                    ? Center(
                        child: Text(
                          '等待日志输出…',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                        children: _lines,
                      ),
              ),
              if (!_follow)
                Positioned(
                  right: 24,
                  bottom: 16,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      setState(() => _follow = true);
                      if (_scroll.hasClients) {
                        _scroll.jumpTo(_scroll.position.maxScrollExtent);
                      }
                    },
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    label: const Text('回到底部并跟随'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
