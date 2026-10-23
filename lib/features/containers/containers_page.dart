/// 容器页（#17 / ui-ia.md D1 方案 A + D2 A1）：列表 + 检查器标签页。
///
/// 数据源 = ContainerService（T2a）：snapshots broadcast + 自适应轮询
/// （页可见时前台节奏，由 service 的 interval 参数决定）。运行时未就绪
/// 遵循 D8 全局态，复用统一占位页。写操作（启动/停止/删除）归 #18，
/// 本页只读。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/placeholders.dart';
import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../system/readiness_controller.dart';
import 'container_detail.dart';

/// 容器列表页：工具栏（搜索/计数/刷新）+ 表头 + 行列表。
class ContainersPage extends StatefulWidget {
  const ContainersPage({
    super.key,
    required this.service,
    required this.controller,
    required this.onOpenRuntime,
  });

  final ContainerService service;
  final ReadinessController controller;

  /// 「打开引导检查」次按钮（跳到运行时页），与占位页语义一致。
  final VoidCallback onOpenRuntime;

  @override
  State<ContainersPage> createState() => _ContainersPageState();
}

class _ContainersPageState extends State<ContainersPage> {
  List<ContainerSnapshotInfo> _snapshot = const [];
  bool _loading = true;
  Object? _error;
  String _search = '';
  String? _selectedId;
  StreamSubscription<List<ContainerSnapshotInfo>>? _sub;

  bool get _ready => widget.controller.readiness?.ready ?? false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncWithReadiness);
    _syncWithReadiness();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncWithReadiness);
    _teardown();
    super.dispose();
  }

  /// 就绪状态变化时接/断数据流（D8：未就绪是全局态）。
  void _syncWithReadiness() {
    if (_ready && _sub == null) {
      _sub = widget.service.snapshots.listen(_onSnapshot);
      widget.service.startPolling(foreground: true);
      _refresh();
    } else if (!_ready && _sub != null) {
      _teardown();
    }
    if (mounted) setState(() {});
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    widget.service.stopPolling();
  }

  void _onSnapshot(List<ContainerSnapshotInfo> snapshot) {
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
      _error = null;
      // 选中项被外部删除时退回列表（service 层 hint 语义）。
      if (_selectedId != null && !snapshot.any((c) => c.id == _selectedId)) {
        _selectedId = null;
      }
    });
  }

  Future<void> _refresh() async {
    try {
      await widget.service.refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  List<ContainerSnapshotInfo> get _filtered {
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return _snapshot;
    return _snapshot
        .where(
          (c) =>
              c.id.toLowerCase().contains(query) ||
              c.image.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return PlaceholderSectionPage(
        title: '容器',
        controller: widget.controller,
        onOpenRuntime: widget.onOpenRuntime,
      );
    }
    final selectedId = _selectedId;
    if (selectedId != null) {
      return ContainerDetailView(
        key: ValueKey(selectedId),
        service: widget.service,
        containerId: selectedId,
        onBack: () => setState(() => _selectedId = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(context),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    final running = _snapshot
        .where((c) => c.state == ContainerState.running)
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          SizedBox(
            width: 280,
            height: 32,
            child: TextField(
              decoration: const InputDecoration(
                hintText: '搜索名称或镜像',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(),
              ),
              style: theme.textTheme.bodySmall,
              onChanged: (value) => setState(() => _search = value),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            '$running 运行中 / 共 ${_snapshot.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _refresh,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _snapshot.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _snapshot.isEmpty) {
      return _ErrorState(error: _error!, onRetry: _refresh);
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _search.isEmpty
          ? const _EmptyState()
          : Center(
              child: Text(
                '没有匹配「$_search」的容器',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
    }
    return Column(
      children: [
        const _ListHeader(),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => _ContainerRow(
              container: rows[index],
              onTap: () => setState(() => _selectedId = rows[index].id),
            ),
          ),
        ),
      ],
    );
  }
}

/// 表头（macos-ui-standards：表头行高 32）。
class _ListHeader extends StatelessWidget {
  const _ListHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.outline);
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          SizedBox(width: 22, child: Text('', style: style)),
          Expanded(flex: 3, child: Text('名称', style: style)),
          Expanded(flex: 4, child: Text('镜像', style: style)),
          Expanded(flex: 2, child: Text('端口', style: style)),
          SizedBox(width: 90, child: Text('运行时长', style: style)),
        ],
      ),
    );
  }
}

/// 单行数据行（≥40；状态点 + 名称[本应用创建标记] + 镜像 + 端口 + 时长）。
class _ContainerRow extends StatelessWidget {
  const _ContainerRow({required this.container, required this.onTap});

  final ContainerSnapshotInfo container;
  final VoidCallback onTap;

  bool get _ownedByApp =>
      container.labels.keys.any((k) => k.startsWith('com.ghost233.'));

  String get _ports => container.publishedPorts.isEmpty
      ? '—'
      : container.publishedPorts
            .map((p) => '${p.hostPort}→${p.containerPort}')
            .join(', ');

  String get _uptime {
    final started = container.startedAt;
    if (container.state != ContainerState.running || started == null) {
      return '—';
    }
    return formatDuration(DateTime.now().difference(started));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: ContainerStateDot(state: container.state),
            ),
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      container.id,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_ownedByApp) ...[
                    const SizedBox(width: 6),
                    const AppOwnedTag(),
                  ],
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                container.image,
                style: monoTextStyle(context),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _ports,
                style: monoTextStyle(context),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(_uptime, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// 生命周期状态点（运行绿 / 停止灰 / 停止中琥珀 / 未知灰轮廓）。
class ContainerStateDot extends StatelessWidget {
  const ContainerStateDot({super.key, required this.state});

  final ContainerState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (state) {
      ContainerState.running => const Color(0xFF1D7A34),
      ContainerState.stopping => const Color(0xFF8A6D00),
      _ => scheme.outline,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 「本应用创建」标记（labels 含 com.ghost233.* 前缀）。
class AppOwnedTag extends StatelessWidget {
  const AppOwnedTag({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '本应用创建',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer, fontSize: 10),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('暂无容器', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            '新建容器能力将在后续版本提供',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text('容器列表加载失败', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              error.toString(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 等宽小字（镜像/端口/路径/标识；macos-ui-standards 字体角色）。
TextStyle? monoTextStyle(BuildContext context) {
  return Theme.of(context).textTheme.bodySmall
      ?.copyWith(fontFamily: 'Menlo', fontFamilyFallback: const ['monospace']);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return value >= 10
      ? '${value.round()} ${units[unit]}'
      : '${value.toStringAsFixed(1)} ${units[unit]}';
}

String formatDuration(Duration duration) {
  if (duration.inMinutes < 1) return '${duration.inSeconds} 秒';
  if (duration.inHours < 1) return '${duration.inMinutes} 分钟';
  if (duration.inDays < 1) return '${duration.inHours} 小时';
  return '${duration.inDays} 天';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
