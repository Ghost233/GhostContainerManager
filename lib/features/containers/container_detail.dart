/// 容器检查器（#26 P1b 重做）：概览卡片化 + stats 实时图表 + 日志 + 终端。
///
/// 概览 = SectionCard 分组（Overview/Image/Process/Network/Labels/Environment）
///   + 四张 fl_chart 实时折线（CPU%/内存/网络速率/磁盘速率）；
/// 日志 = XPC 双 FileHandle 流；终端 = 非 TTY argv exec。
/// 设计基线 docs/design.md；共享组件 lib/ui/。
library;

import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../services/container_logs_parser.dart';
import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../ui/colors.dart';
import '../../ui/components.dart';
import '../../ui/motion.dart';
import '../../ui/text.dart';
import 'containers_page.dart'
    show ContainerActivityLabel, ContainerStateDot, ContainerStateLabel;
import 'stats_chart.dart';

/// 容器详情：标题栏（返回 + 名称 + 状态 + 操作组）+ 三标签页。
class ContainerDetailView extends StatefulWidget {
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
  State<ContainerDetailView> createState() => _ContainerDetailViewState();
}

class _ContainerDetailViewState extends State<ContainerDetailView> {
  late final Future<ContainerSnapshotInfo> _detail = widget.service.inspect(
    widget.containerId,
  );
  late final StreamSubscription<Map<String, ContainerActivity>>
  _activitySubscription;
  ContainerActivity? _activity;

  @override
  void initState() {
    super.initState();
    _activity = widget.service.currentActivities[widget.containerId];
    _activitySubscription = widget.service.activityChanges.listen((activities) {
      final next = activities[widget.containerId];
      if (!mounted || next == _activity) return;
      setState(() => _activity = next);
    });
    // 进入详情即把该容器设为前台 stats 采样目标（task-40 接缝）。
    widget.service.setStatsTarget(widget.containerId);
  }

  @override
  void dispose() {
    unawaited(_activitySubscription.cancel());
    widget.service.setStatsTarget(null);
    super.dispose();
  }

  Future<void> _toggle(ContainerSnapshotInfo info) async {
    try {
      if (info.state == ContainerState.running) {
        await widget.service.stop(widget.containerId);
      } else {
        await widget.service.start(widget.containerId);
      }
    } catch (_) {
      // 错误由列表/活动流呈现；详情操作失败不阻断。
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<ContainerSnapshotInfo>(
      future: _detail,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final running = info?.state == ContainerState.running;
        final activity = _activity;
        final busy = activity != null || info?.state == ContainerState.stopping;
        return DefaultTabController(
          length: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.chevron_left, size: 18),
                      label: const Text('返回容器列表'),
                    ),
                    const SizedBox(width: 8),
                    if (info != null) ...[
                      ContainerStateDot(state: info.state),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        widget.containerId,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (info != null) ...[
                      const SizedBox(width: 12),
                      // 主操作语义色：Stop=警示橙，Start=运行绿。
                      FilledButton.icon(
                        key: const Key('container-detail-toggle'),
                        style: FilledButton.styleFrom(
                          backgroundColor: running
                              ? GcmColors.stateTransition
                              : GcmColors.stateRunning,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(88, 32),
                        ),
                        onPressed: busy ? null : () => _toggle(info),
                        icon: busy
                            ? const GcmInlineSpinner()
                            : Icon(
                                running ? Icons.stop : Icons.play_arrow,
                                size: 16,
                              ),
                        label: Text(activity?.label ?? info.state.label),
                      ),
                    ],
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '概览'),
                  Tab(text: '日志'),
                  Tab(text: '终端'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _OverviewTab(
                      service: widget.service,
                      containerId: widget.containerId,
                      detail: _detail,
                    ),
                    ContainerLogTab(
                      service: widget.service,
                      containerId: widget.containerId,
                    ),
                    _ContainerTerminalTab(
                      service: widget.service,
                      containerId: widget.containerId,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 概览：配置卡片组 + stats 实时图表。
class _OverviewTab extends StatefulWidget {
  const _OverviewTab({
    required this.service,
    required this.containerId,
    required this.detail,
  });

  final ContainerService service;
  final String containerId;
  final Future<ContainerSnapshotInfo> detail;

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ContainerSnapshotInfo>(
      future: widget.detail,
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
            _StatsChartsCard(
              service: widget.service,
              containerId: widget.containerId,
            ),
            const SizedBox(height: 24),
            _OverviewCard(info: info),
            const SizedBox(height: 24),
            _ImageCard(info: info),
            const SizedBox(height: 24),
            _ProcessCard(info: info),
            const SizedBox(height: 24),
            _NetworkCard(info: info),
            const SizedBox(height: 24),
            _LabelsCard(info: info),
            const SizedBox(height: 24),
            _EnvironmentCard(info: info),
          ],
        );
      },
    );
  }
}

/// label 灰 + value 两列行。
class _KvRow extends StatelessWidget {
  const _KvRow(this.label, this.value, {this.mono = false, this.valueWidget});

  final String label;
  final String value;
  final bool mono;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: GcmColors.textSecondary(context),
              ),
            ),
          ),
          Expanded(
            child:
                valueWidget ??
                SelectableText(
                  value.isEmpty ? '—' : value,
                  style: mono
                      ? monoTextStyle(context)
                      : theme.textTheme.bodyMedium,
                ),
          ),
        ],
      ),
    );
  }
}

/// Overview 卡：名称/ID + 状态 + 创建/启动时间。
class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.info});

  final ContainerSnapshotInfo info;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '概览',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KvRow('名称 / ID', info.id, valueWidget: CopyValue(value: info.id)),
          _KvRow(
            '状态',
            info.state.wireName,
            valueWidget: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ContainerStateDot(state: info.state),
                const SizedBox(width: 6),
                Text(
                  info.state.wireName,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          _KvRow(
            '创建时间',
            info.createdAt == null ? '—' : formatDateTime(info.createdAt!),
          ),
          _KvRow(
            '启动时间',
            info.startedAt == null ? '—' : formatDateTime(info.startedAt!),
          ),
        ],
      ),
    );
  }
}

/// Image 卡：镜像引用（CopyValue）。
class _ImageCard extends StatelessWidget {
  const _ImageCard({required this.info});

  final ContainerSnapshotInfo info;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '镜像',
      child: _KvRow(
        '引用',
        info.image,
        valueWidget: CopyValue(value: info.image),
      ),
    );
  }
}

/// Process 卡：入口命令 + 停止信号。
class _ProcessCard extends StatelessWidget {
  const _ProcessCard({required this.info});

  final ContainerSnapshotInfo info;

  @override
  Widget build(BuildContext context) {
    final command = [
      info.initCommand,
      ...info.initArguments,
    ].where((s) => s.isNotEmpty).join(' ');
    return SectionCard(
      title: '进程',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KvRow('入口命令', command, mono: true),
          _KvRow('停止信号', info.stopSignal, mono: true),
        ],
      ),
    );
  }
}

/// Network 卡：网络附件 + 端口映射。
class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.info});

  final ContainerSnapshotInfo info;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '网络',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (info.networks.isEmpty)
            _KvRow('网络', '—')
          else
            for (final network in info.networks)
              _KvRow(
                network.network,
                '${network.address.isEmpty ? '—' : network.address}'
                '（网关 ${network.gateway.isEmpty ? '—' : network.gateway}）',
                mono: true,
              ),
          _KvRow(
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
        ],
      ),
    );
  }
}

/// Labels 卡：键值对（CopyValue 可复制）。
class _LabelsCard extends StatelessWidget {
  const _LabelsCard({required this.info});

  final ContainerSnapshotInfo info;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '标签',
      child: info.labels.isEmpty
          ? Text(
              '—',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: GcmColors.textSecondary(context)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in info.labels.entries)
                  _KvRow(
                    entry.key,
                    entry.value,
                    valueWidget: CopyValue(value: entry.value),
                  ),
              ],
            ),
    );
  }
}

/// Environment 卡：敏感值默认打码（MaskedValue）。
class _EnvironmentCard extends StatelessWidget {
  const _EnvironmentCard({required this.info});

  final ContainerSnapshotInfo info;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '环境变量',
      child: info.environment.isEmpty
          ? Text(
              '—',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: GcmColors.textSecondary(context)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in info.environment) _EnvRow(entry: entry),
              ],
            ),
    );
  }
}

/// 单条环境变量：KEY=VALUE 拆分，VALUE 用 MaskedValue 打码。
class _EnvRow extends StatelessWidget {
  const _EnvRow({required this.entry});

  final String entry;

  @override
  Widget build(BuildContext context) {
    final separator = entry.indexOf('=');
    final key = separator < 0 ? entry : entry.substring(0, separator);
    final value = separator < 0 ? '' : entry.substring(separator + 1);
    return _KvRow(key, value, valueWidget: MaskedValue(value: value));
  }
}

/// Stats 实时图表卡：四张折线（CPU%/内存/网络速率/磁盘速率）+ 5m/15m 切换。
class _StatsChartsCard extends StatefulWidget {
  const _StatsChartsCard({required this.service, required this.containerId});

  final ContainerService service;
  final String containerId;

  @override
  State<_StatsChartsCard> createState() => _StatsChartsCardState();
}

class _StatsChartsCardState extends State<_StatsChartsCard> {
  /// 时间窗：5 分钟或 15 分钟。
  Duration _window = const Duration(minutes: 5);
  StreamSubscription<List<ContainerStatsSample>>? _sub;
  List<ContainerStatsSample> _history = const [];

  @override
  void initState() {
    super.initState();
    _history = widget.service.statsHistoryFor(widget.containerId);
    _sub = widget.service.statsHistoryChanges.listen((samples) {
      if (!mounted) return;
      setState(() => _history = samples);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _setWindow(Duration window) {
    setState(() => _window = window);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final cutoff = now.subtract(_window);
    final visible = statsSamplesInWindow(_history, now: now, window: _window);
    final latest = visible.isEmpty ? null : visible.last;

    return SectionCard(
      title: '资源占用',
      actions: [_WindowToggle(window: _window, onChanged: _setWindow)],
      child: visible.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '暂无统计数据（容器需运行中）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: GcmColors.textSecondary(context),
                  ),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _ChartPanel(
                        title: 'CPU',
                        current: latest?.cpuPercent == null
                            ? '—'
                            : '${latest!.cpuPercent!.toStringAsFixed(1)}%',
                        spots: _spots(visible, (s) => s.cpuPercent),
                        color: GcmColors.stateRunning,
                        cutoff: cutoff,
                        end: now,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _ChartPanel(
                        title: '内存',
                        current: latest?.memoryBytes == null
                            ? '—'
                            : formatBytes(latest!.memoryBytes!),
                        spots: _spots(
                          visible,
                          (s) => s.memoryBytes?.toDouble(),
                        ),
                        color: theme.colorScheme.primary,
                        cutoff: cutoff,
                        end: now,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _ChartPanel(
                        title: '网络接收',
                        current: latest?.networkRxBytes == null
                            ? '—'
                            : formatBytes(latest!.networkRxBytes!),
                        spots: _spots(
                          visible,
                          (s) => s.networkRxBytes?.toDouble(),
                        ),
                        color: GcmColors.stateTransition,
                        cutoff: cutoff,
                        end: now,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _ChartPanel(
                        title: '磁盘读取',
                        current: latest?.diskReadBytes == null
                            ? '—'
                            : formatBytes(latest!.diskReadBytes!),
                        spots: _spots(
                          visible,
                          (s) => s.diskReadBytes?.toDouble(),
                        ),
                        color: GcmColors.stateFailed(context),
                        cutoff: cutoff,
                        end: now,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  List<FlSpot> _spots(
    List<ContainerStatsSample> samples,
    double? Function(ContainerStatsSample) value,
  ) {
    return statsChartSpots(samples, value);
  }
}

/// 5m/15m 时间窗切换（SegmentedControl 风格）。
class _WindowToggle extends StatelessWidget {
  const _WindowToggle({required this.window, required this.onChanged});

  final Duration window;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget segment(String label, Duration value) {
      final selected = window == value;
      return InkWell(
        key: Key('stats-window-${value.inMinutes}m'),
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.secondaryContainer : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? theme.colorScheme.onSecondaryContainer
                  : GcmColors.textSecondary(context),
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment('5m', const Duration(minutes: 5)),
          segment('15m', const Duration(minutes: 15)),
        ],
      ),
    );
  }
}

/// 单张图表：标题 + 当前值大数字 + 折线。
class _ChartPanel extends StatelessWidget {
  const _ChartPanel({
    required this.title,
    required this.current,
    required this.spots,
    required this.color,
    required this.cutoff,
    required this.end,
  });

  final String title;
  final String current;
  final List<FlSpot> spots;
  final Color color;
  final DateTime cutoff;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = splitStatsChartSpots(spots);
    final hasLine = segments.any((segment) => segment.length >= 2);
    final window = end.difference(cutoff);
    final tickInterval = window == const Duration(minutes: 5)
        ? const Duration(minutes: 2)
        : const Duration(minutes: 5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              title,
              style: theme.textTheme.labelSmall?.copyWith(
                color: GcmColors.textSecondary(context),
              ),
            ),
            const SizedBox(width: 8),
            Text(current, style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 72,
          child: !hasLine
              ? Center(
                  child: Text(
                    '数据不足',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: GcmColors.textSecondary(context),
                    ),
                  ),
                )
              : LineChart(
                  LineChartData(
                    minX: cutoff.millisecondsSinceEpoch.toDouble(),
                    maxX: end.millisecondsSinceEpoch.toDouble(),
                    gridData: const FlGridData(show: false),
                    titlesData: FlTitlesData(
                      show: true,
                      leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          interval: tickInterval.inMilliseconds.toDouble(),
                          getTitlesWidget: (value, meta) => SideTitleWidget(
                            meta: meta,
                            space: 4,
                            child: Text(
                              _formatStatsTick(value),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: GcmColors.textSecondary(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    lineBarsData: [
                      for (final segment in segments)
                        if (segment.length >= 2)
                          LineChartBarData(
                            spots: segment,
                            isCurved: true,
                            color: color,
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: color.withValues(alpha: 0.12),
                            ),
                          ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

String _formatStatsTick(double milliseconds) {
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt());
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// 一次性终端：只提交 argv，不在主机或容器内隐式启动 shell。
class _ContainerTerminalTab extends StatefulWidget {
  const _ContainerTerminalTab({
    required this.service,
    required this.containerId,
  });

  final ContainerService service;
  final String containerId;

  @override
  State<_ContainerTerminalTab> createState() => _ContainerTerminalTabState();
}

class _ContainerTerminalTabState extends State<_ContainerTerminalTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _command = TextEditingController();
  ContainerExecResult? _result;
  Object? _error;
  bool _running = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  Future<void> _execute() async {
    if (_running) return;
    final List<String> command;
    try {
      command = _parseArgv(_command.text);
    } on FormatException catch (error) {
      setState(() {
        _error = error;
        _result = null;
      });
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await widget.service.exec(
        widget.containerId,
        command: command,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final result = _result;
    final error = _error;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('一次性终端', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          '非 TTY；按 argv 执行并支持引号，不经过 shell。需要管道或重定向时请显式运行 /bin/sh -c。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: GcmColors.textSecondary(context),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                height: 32,
                child: TextField(
                  key: const Key('container-terminal-command'),
                  controller: _command,
                  enabled: !_running,
                  style: monoTextStyle(context),
                  decoration: const InputDecoration(
                    hintText: '命令与参数，例如：printf "hello world"',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => _execute(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const Key('container-terminal-run'),
              style: FilledButton.styleFrom(minimumSize: const Size(88, 32)),
              onPressed: _running ? null : _execute,
              child: Text(_running ? '执行中…' : '执行'),
            ),
          ],
        ),
        if (_running) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (error != null) ...[
          const SizedBox(height: 16),
          Text(
            '执行失败：$error',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (result != null) ...[
          const SizedBox(height: 16),
          Text(
            '退出码 ${result.exitCode}',
            key: const Key('container-terminal-exit-code'),
            style: theme.textTheme.titleSmall?.copyWith(
              color: result.exitCode == 0 ? null : theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          _TerminalOutput(
            label: 'stdout',
            output: result.stdout,
            truncated: result.stdoutTruncated,
          ),
          const SizedBox(height: 12),
          _TerminalOutput(
            label: 'stderr',
            output: result.stderr,
            truncated: result.stderrTruncated,
          ),
        ],
      ],
    );
  }
}

class _TerminalOutput extends StatelessWidget {
  const _TerminalOutput({
    required this.label,
    required this.output,
    required this.truncated,
  });

  final String label;
  final String output;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (truncated)
            Text(
              '$label 已截断至 64 KiB，仅显示保留的前缀',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (truncated) const SizedBox(height: 8),
          SelectableText(
            output.isEmpty ? '（无输出）' : output,
            style: monoTextStyle(context),
          ),
        ],
      ),
    );
  }
}

List<String> _parseArgv(String input) {
  final arguments = <String>[];
  final current = StringBuffer();
  String? quote;
  var escaped = false;
  var started = false;
  for (final character in input.runes) {
    final value = String.fromCharCode(character);
    if (escaped) {
      current.write(value);
      escaped = false;
      started = true;
    } else if (value == r'\' && quote != "'") {
      escaped = true;
      started = true;
    } else if (quote != null) {
      if (value == quote) {
        quote = null;
      } else {
        current.write(value);
      }
      started = true;
    } else if (value == "'" || value == '"') {
      quote = value;
      started = true;
    } else if (value.trim().isEmpty) {
      if (started) {
        arguments.add(current.toString());
        current.clear();
        started = false;
      }
    } else {
      current.write(value);
      started = true;
    }
  }
  if (escaped || quote != null) {
    throw const FormatException('命令包含未闭合的引号或转义符');
  }
  if (started) arguments.add(current.toString());
  if (arguments.isEmpty || arguments.first.isEmpty) {
    throw const FormatException('请输入要执行的命令');
  }
  return List<String>.unmodifiable(arguments);
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
  static const int _maxLogLines = 5000;

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
      if (_lines.length > _maxLogLines) {
        _lines.removeRange(0, _lines.length - _maxLogLines);
      }
    });
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
  }

  void _scrollToLatest() {
    if (!mounted || !_scroll.hasClients) return;
    unawaited(
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: GcmMotion.scrollFollowDuration,
        curve: GcmMotion.scrollFollowCurve,
      ),
    );
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
              color: GcmColors.textSecondary(context),
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
                      _scrollToLatest();
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
