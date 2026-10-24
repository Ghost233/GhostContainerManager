/// 容器页（#17/#18）：列表 + 检查器标签页 + 生命周期写操作。
///
/// 数据源 = ContainerService：snapshots 与 activityChanges broadcast。
/// 原生四态和创建/启动/停止/重启/删除合成态都在列表即时呈现；
/// UI 只收集确认和表单输入，状态分叉与 per-resource 锁归 Service。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/placeholders.dart';
import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../services/errors.dart';
import '../../ui/colors.dart';
import '../../ui/components.dart';
import '../../ui/motion.dart';
import '../../ui/text.dart';
import '../system/readiness_controller.dart';
import 'container_detail.dart';
import 'container_dialogs.dart';

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
  StreamSubscription<Map<String, ContainerActivity>>? _activitySub;
  Map<String, ContainerActivity> _activities = const {};

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
      _activities = widget.service.currentActivities;
      _activitySub = widget.service.activityChanges.listen(_onActivities);
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
    _activitySub?.cancel();
    _activitySub = null;
    _activities = const {};
    widget.service.stopPolling();
  }

  void _onActivities(Map<String, ContainerActivity> activities) {
    if (!mounted) return;
    setState(() => _activities = activities);
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

  Future<void> _createContainer() async {
    final draft = await showContainerCreateDialog(
      context,
      loadLocalImages: widget.service.listLocalImages,
    );
    if (draft == null) return;
    try {
      await widget.service.create(
        id: draft.id,
        image: draft.image,
        command: draft.command,
        env: draft.env,
        ports: draft.ports,
        network: draft.network,
        mounts: draft.mounts,
        labels: draft.labels,
        start: draft.start,
      );
    } catch (error) {
      _showActionError(error);
    }
  }

  Future<void> _handleContainerAction(
    ContainerSnapshotInfo container,
    String action,
  ) async {
    if (action == 'delete') {
      final force = await showContainerDeleteConfirmation(context, container);
      if (force == null) return;
      await _runAction(() => widget.service.delete(container.id, force: force));
      return;
    }
    final (title, message, confirmText) = switch (action) {
      'start' => ('启动容器', '确定启动容器「${container.id}」吗？', '启动'),
      'stop' => (
        '停止容器',
        '将先优雅停止「${container.id}」，5 秒后仍未退出会由 runtime 发送 SIGKILL。',
        '停止',
      ),
      'restart' => ('重启容器', '将先停止再启动「${container.id}」，该合成操作不是原子操作。', '重启'),
      _ => ('', '', ''),
    };
    if (title.isEmpty) return;
    final confirmed = await showContainerConfirmation(
      context,
      title: title,
      message: message,
      confirmText: confirmText,
    );
    if (!confirmed) return;
    await _runAction(
      () => switch (action) {
        'start' => widget.service.start(container.id),
        'stop' => _stopContainer(container.id),
        'restart' => widget.service.restart(container.id),
        _ => Future<void>.value(),
      },
    );
  }

  Future<void> _stopContainer(String id) {
    return widget.service
        .stop(id)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw const GcmException(
              GcmErrorCode.timeout,
              '停止容器等待超过 15 秒。',
              hint: '后台停止操作仍会继续，请稍后刷新状态。',
            );
          },
        );
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _showActionError(error);
    }
  }

  void _showActionError(Object error) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error is GcmException
              ? '${error.code.name}: ${error.message}'
                    '${error.hint == null ? '' : '\n${error.hint}'}'
              : '$error',
        ),
      ),
    );
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const Key('containers-list-pane'),
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildToolbar(context),
              Expanded(child: _buildBody(context, compact: true)),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          key: const Key('containers-detail-pane'),
          child: selectedId == null
              ? const _DetailEmptyState()
              : ContainerDetailView(
                  key: ValueKey(selectedId),
                  service: widget.service,
                  containerId: selectedId,
                  onBack: () => setState(() => _selectedId = null),
                ),
        ),
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 640;
          final search = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: SizedBox(
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
          );
          final refresh = IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _refresh,
          );
          if (compact) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 8),
                    IconButton(
                      key: const Key('create-container-button'),
                      tooltip: '新建容器',
                      icon: const Icon(Icons.add, size: 18),
                      onPressed: _createContainer,
                    ),
                    refresh,
                  ],
                ),
                Text(
                  '$running 运行中 / 共 ${_snapshot.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            );
          }
          return Row(
            children: [
              Flexible(child: search),
              const SizedBox(width: 16),
              Text(
                '$running 运行中 / 共 ${_snapshot.length}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const Key('create-container-button'),
                onPressed: _createContainer,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建容器'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              const SizedBox(width: 8),
              refresh,
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, {bool compact = false}) {
    if (_loading && _snapshot.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _snapshot.isEmpty) {
      return _ErrorState(error: _error!, onRetry: _refresh);
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _search.isEmpty
          ? _EmptyState(onCreate: _createContainer)
          : Center(
              child: Text(
                '没有匹配「$_search」的容器',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
    }
    return Column(
      children: [
        _ListHeader(compact: compact),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => _ContainerRow(
              key: Key('container-row-${rows[index].id}'),
              container: rows[index],
              activity: _activities[rows[index].id],
              selected: _selectedId == rows[index].id,
              compact: compact,
              onTap: () => setState(() {
                final id = rows[index].id;
                _selectedId = _selectedId == id ? null : id;
              }),
              onAction: (action) => _handleContainerAction(rows[index], action),
            ),
          ),
        ),
      ],
    );
  }
}

/// 表头（macos-ui-standards：表头行高 32）。
class _ListHeader extends StatelessWidget {
  const _ListHeader({this.compact = false});

  final bool compact;

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
          Expanded(flex: 8, child: Text('名称 / 镜像 / 端口', style: style)),
          SizedBox(width: 76, child: Text('状态', style: style)),
          if (!compact) SizedBox(width: 90, child: Text('运行时长', style: style)),
          SizedBox(width: 40, child: compact ? null : Text('操作', style: style)),
        ],
      ),
    );
  }
}

/// 双行数据行（≥56；状态点 + 名称[本应用创建标记]）。
///
/// 次行展示镜像与端口，状态、运行时长与操作保持独立列。
class _ContainerRow extends StatelessWidget {
  const _ContainerRow({
    super.key,
    required this.container,
    required this.activity,
    required this.onTap,
    required this.onAction,
    this.selected = false,
    this.compact = false,
  });

  final ContainerSnapshotInfo container;
  final ContainerActivity? activity;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;

  bool get _ownedByApp =>
      container.labels.keys.any((k) => k.startsWith('com.ghost233.'));

  bool get _busy =>
      activity != null || container.state == ContainerState.stopping;

  String get _status => activity?.label ?? container.state.label;

  String get _stateName {
    final current = activity;
    if (current == null) return container.state.wireName;
    return switch (current) {
      ContainerActivity.creating || ContainerActivity.starting => 'starting',
      ContainerActivity.stopping => 'stopping',
      ContainerActivity.restarting => 'restarting',
      ContainerActivity.deleting => 'deleting',
    };
  }

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
    final scheme = theme.colorScheme;
    final stateName = _stateName;
    final stateColor = GcmColors.stateColorOf(context, stateName);
    final secondaryStyle = monoTextStyle(context)?.copyWith(
      color: GcmColors.textSecondary(context),
      fontSize: theme.textTheme.bodySmall?.fontSize,
    );
    final secondaryText = '${container.image} · 端口 $_ports';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      highlightColor: scheme.secondaryContainer.withValues(alpha: 0.35),
      splashColor: scheme.secondaryContainer.withValues(alpha: 0.5),
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.secondaryContainer.withValues(alpha: 0.45)
              : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            SizedBox(width: 22, child: StateDot(state: stateName, size: 8)),
            Expanded(
              flex: 8,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          container.id,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: selected
                                ? scheme.onSecondaryContainer
                                : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_ownedByApp) ...[
                        const SizedBox(width: 6),
                        const AppOwnedTag(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Tooltip(
                    message: secondaryText,
                    child: Text(
                      secondaryText,
                      style: secondaryStyle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                _status,
                key: Key('container-status-${container.id}'),
                style: theme.textTheme.bodySmall?.copyWith(color: stateColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!compact)
              SizedBox(
                width: 90,
                child: Text(
                  _uptime,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: GcmColors.textSecondary(context),
                  ),
                ),
              ),
            SizedBox(
              width: 40,
              child: PopupMenuButton<String>(
                key: Key('container-actions-${container.id}'),
                tooltip: _busy ? _status : '容器操作',
                enabled: !_busy,
                icon: _busy ? const GcmInlineSpinner() : null,
                onSelected: onAction,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'start',
                    enabled:
                        container.state == ContainerState.stopped ||
                        container.state == ContainerState.unknown,
                    child: const Text('启动'),
                  ),
                  PopupMenuItem(
                    value: 'stop',
                    enabled:
                        container.state == ContainerState.running ||
                        container.state == ContainerState.unknown,
                    child: const Text('停止'),
                  ),
                  const PopupMenuItem(value: 'restart', child: Text('重启')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension ContainerStateLabel on ContainerState {
  String get label => switch (this) {
    ContainerState.unknown => '未知',
    ContainerState.stopped => '已停止',
    ContainerState.running => '运行中',
    ContainerState.stopping => '停止中',
  };
}

extension ContainerActivityLabel on ContainerActivity {
  String get label => switch (this) {
    ContainerActivity.creating => '创建中',
    ContainerActivity.starting => '启动中',
    ContainerActivity.stopping => '停止中',
    ContainerActivity.restarting => '重启中',
    ContainerActivity.deleting => '删除中',
  };
}

/// 生命周期状态点（语义色经 GcmColors 映射，配文字标签使用）。
class ContainerStateDot extends StatelessWidget {
  const ContainerStateDot({super.key, required this.state});

  final ContainerState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: GcmColors.stateColorOf(context, state.wireName),
        shape: BoxShape.circle,
      ),
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

class _DetailEmptyState extends StatelessWidget {
  const _DetailEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 40,
            color: GcmColors.textSecondary(context),
          ),
          const SizedBox(height: 12),
          Text('选择一个容器查看详情', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            '列表会保持显示，可随时切换容器',
            style: theme.textTheme.bodySmall?.copyWith(
              color: GcmColors.textSecondary(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

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
            '从本地镜像创建第一个容器',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('empty-create-container-button'),
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('新建容器'),
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
