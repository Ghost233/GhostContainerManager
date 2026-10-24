/// 项目详情（D11 终轮版）：标题栏操作组 + 镜像列表卡 + 成员容器表 +
/// 回收报告卡 + 底部构建日志面板（与卡片区块共存）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/container_models.dart';
import '../../services/container_service.dart';
import '../../services/errors.dart';
import '../../services/image_service.dart';
import '../../services/project_service.dart';
import '../../ui/text.dart';
import '../containers/container_detail.dart' show ContainerLogTab;
import '../containers/containers_page.dart' show ContainerStateDot;
import 'project_dialogs.dart';

/// 构建日志面板状态。
///
/// cancelled：构建/推送被用户取消。当前 ProjectBuildResult 无取消标记
/// （仅 exitCode），service 层不可区分取消与失败，故取消暂归 failed；
/// 保留此态待 service 暴露取消信号后映射。
enum BuildLogState { closed, running, success, failed, cancelled }

class ProjectDetailView extends StatefulWidget {
  const ProjectDetailView({
    super.key,
    required this.service,
    required this.containerService,
    required this.imageService,
    required this.project,
    required this.onBack,
  });

  final ProjectService service;
  final ContainerService containerService;
  final ImageService imageService;
  final String project;
  final VoidCallback onBack;

  @override
  State<ProjectDetailView> createState() => _ProjectDetailViewState();
}

class _ProjectDetailViewState extends State<ProjectDetailView> {
  ProjectDetails? _details;
  Object? _error;
  bool _loading = true;

  /// 上次回收报告（dryRun=false 完成后展示）。
  ProjectReclaimReport? _lastReclaim;

  /// 上次回收完成时间（报告卡时间注记）。
  DateTime? _lastReclaimAt;

  /// 构建日志面板。
  BuildLogState _logState = BuildLogState.closed;
  String _logTitle = '';
  final List<String> _logLines = [];
  String? _lastFailureLogPath;
  int _buildSequence = 0;

  /// 日志面板滚动控制器：新行追加时自动跟随到底部。
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    super.dispose();
  }

  /// 日志追加后滚动到底部（自动跟随最新输出）。
  void _scrollLogToBottom() {
    if (!_logScrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(
          _logScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  Future<void> _refresh() async {
    try {
      final details = await widget.service.getProject(project: widget.project);
      if (!mounted) return;
      setState(() {
        _details = details;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  /// 下一个构建镜像名：自由命名 {prefix}-{自定义名}，UI 默认 go{n} 递增。
  String get _nextBuildName {
    final images = _details?.images ?? const <ProjectImageStatus>[];
    var max = 0;
    final pattern = RegExp(
      '^${RegExp.escape(widget.project)}-go(\\d+):latest\$',
    );
    for (final image in images) {
      final match = pattern.firstMatch(image.reference);
      if (match != null) {
        final n = int.tryParse(match.group(1)!) ?? 0;
        if (n > max) max = n;
      }
    }
    return 'go${max + 1}';
  }

  Future<void> _build() async {
    final name = _nextBuildName;
    final sequence = ++_buildSequence;
    setState(() {
      _logState = BuildLogState.running;
      _logTitle = '构建 ${widget.project}-$name:latest';
      _logLines.clear();
    });
    try {
      final result = await widget.service.buildProject(
        project: widget.project,
        name: name,
        onProgress: (line) {
          if (!mounted || sequence != _buildSequence) return;
          setState(() => _logLines.add(line));
          _scrollLogToBottom();
        },
      );
      if (!mounted || sequence != _buildSequence) return;
      setState(() {
        _logState = result.exitCode == 0
            ? BuildLogState.success
            : BuildLogState.failed;
        if (result.failureLogPath != null) {
          _lastFailureLogPath = result.failureLogPath;
        }
      });
      unawaited(_refresh());
    } catch (error) {
      if (!mounted || sequence != _buildSequence) return;
      setState(() {
        _logState = BuildLogState.failed;
        _logLines.add('$error');
      });
      _scrollLogToBottom();
    }
  }

  /// 推送最新镜像到本地 registry（deleteLocal:false，进度进日志面板）。
  Future<void> _push() async {
    final name = _latestBuiltName;
    final sequence = ++_buildSequence;
    setState(() {
      _logState = BuildLogState.running;
      _logTitle = '推送 ${widget.project}-$name:latest → 127.0.0.1:5056';
      _logLines.clear();
    });
    try {
      await widget.service.publishProject(
        project: widget.project,
        name: name,
        onProgress: (line) {
          if (!mounted || sequence != _buildSequence) return;
          setState(() => _logLines.add(line));
          _scrollLogToBottom();
        },
      );
      if (!mounted || sequence != _buildSequence) return;
      setState(() => _logState = BuildLogState.success);
      unawaited(_refresh());
    } catch (error) {
      if (!mounted || sequence != _buildSequence) return;
      setState(() {
        _logState = BuildLogState.failed;
        _logLines.add('$error');
      });
      _scrollLogToBottom();
    }
  }

  /// 最近构建的镜像名（go{n} 最大值；无则 go1）。
  String get _latestBuiltName {
    final images = _details?.images ?? const <ProjectImageStatus>[];
    var max = 0;
    final pattern = RegExp(
      '^${RegExp.escape(widget.project)}-go(\\d+):latest\$',
    );
    for (final image in images) {
      final match = pattern.firstMatch(image.reference);
      if (match != null) {
        final n = int.tryParse(match.group(1)!) ?? 0;
        if (n > max) max = n;
      }
    }
    return 'go${max == 0 ? 1 : max}';
  }

  Future<void> _showLastFailureLog() async {
    String content;
    final path = _lastFailureLogPath;
    if (path != null) {
      try {
        content = await File(path).readAsString();
      } catch (error) {
        content = '读取失败日志失败：$error';
      }
    } else {
      // 本会话无失败路径时，回退读最新落盘失败日志（跨会话回看）。
      // readLatest 需 imageName，遍历项目镜像取第一个非空结果。
      content = '暂无失败构建日志';
      final images = _details?.images ?? const <ProjectImageStatus>[];
      for (final image in images) {
        try {
          final log = await widget.service.buildLogStore.readLatest(
            project: widget.project,
            imageName: _imageName(image.reference),
          );
          if (log != null) {
            content = log;
            break;
          }
        } catch (_) {
          // 单镜像读取失败继续尝试下一个。
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _logState = BuildLogState.failed;
      _logTitle = '上次失败日志';
      _logLines
        ..clear()
        ..addAll(content.split('\n').where((line) => line.isNotEmpty));
    });
    _scrollLogToBottom();
  }

  Future<void> _reclaim() async {
    // dryRun 预演拿销毁清单。
    ProjectReclaimReport preview;
    try {
      preview = await widget.service.reclaimProject(
        project: widget.project,
        dryRun: true,
      );
    } catch (error) {
      _showError(error);
      return;
    }
    if (!mounted) return;
    final confirmation = await showReclaimDialog(
      context,
      project: widget.project,
      preview: preview,
    );
    if (confirmation == null || !confirmation.confirmed || !mounted) return;
    try {
      final report = await widget.service.reclaimProject(
        project: widget.project,
        force: confirmation.force,
      );
      if (!mounted) return;
      setState(() {
        _lastReclaim = report;
        _lastReclaimAt = DateTime.now();
      });
      unawaited(_refresh());
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _deleteLocalCopy(ProjectImageStatus image) async {
    final choice = await showDeleteLocalCopyDialog(
      context,
      reference: image.reference,
    );
    if (choice == null || !mounted) return;
    final name = _imageName(image.reference);
    try {
      if (choice == DeleteLocalChoice.archiveAndDelete) {
        await widget.service.publishProject(
          project: widget.project,
          name: name,
          deleteLocal: true,
        );
      } else {
        await widget.imageService.delete(image.reference);
      }
      unawaited(_refresh());
    } catch (error) {
      _showError(error);
    }
  }

  String _imageName(String reference) {
    final prefix = '${widget.project}-';
    final suffix = ':latest';
    var name = reference;
    if (name.startsWith(prefix)) name = name.substring(prefix.length);
    if (name.endsWith(suffix)) {
      name = name.substring(0, name.length - suffix.length);
    }
    return name;
  }

  void _showError(Object error) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTitleBar(theme),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text('项目详情加载失败：$_error'))
              : _buildBody(theme),
        ),
        if (_logState != BuildLogState.closed) _buildLogPanel(theme),
      ],
    );
  }

  Widget _buildTitleBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('返回'),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.project,
              style: theme.textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '$projectLabel=${widget.project}',
              style: monoTextStyle(context)
                  ?.copyWith(color: theme.colorScheme.outline, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            key: const Key('build-button'),
            onPressed: _logState == BuildLogState.running ? null : _build,
            icon: const Icon(Icons.build, size: 16),
            label: const Text('构建新版本'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 32)),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('push-button'),
            onPressed: _logState == BuildLogState.running ? null : _push,
            icon: const Icon(Icons.cloud_upload_outlined, size: 16),
            label: const Text('推送到本地 registry…'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32)),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('reclaim-button'),
            onPressed: _reclaim,
            icon: const Icon(Icons.delete_sweep, size: 16),
            label: const Text('一键回收…'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final details = _details!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _buildImagesCard(theme, details),
        const SizedBox(height: 16),
        _buildContainersCard(theme, details),
        if (_lastReclaim != null) ...[
          const SizedBox(height: 16),
          _buildReclaimReportCard(theme, _lastReclaim!),
        ],
      ],
    );
  }

  Widget _buildImagesCard(ThemeData theme, ProjectDetails details) {
    final images = details.images.toList()
      ..sort(
        (a, b) => (b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
      );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('镜像列表', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_lastFailureLogPath != null)
                  TextButton(
                    key: const Key('view-failure-log'),
                    onPressed: _showLastFailureLog,
                    child: const Text('查看上次失败日志'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (final image in images) _buildImageRow(theme, image),
          ],
        ),
      ),
    );
  }

  Widget _buildImageRow(ThemeData theme, ProjectImageStatus image) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              image.reference,
              style: monoTextStyle(context),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 80,
            child: Text(
              image.sizeBytes == null ? '—' : formatBytes(image.sizeBytes!),
              style: theme.textTheme.bodySmall,
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              image.createdAt == null ? '—' : formatDateTime(image.createdAt!),
              style: theme.textTheme.bodySmall,
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              image.inUse ? '使用中' : '未使用',
              style: theme.textTheme.bodySmall?.copyWith(
                color: image.inUse
                    ? const Color(0xFF1D7A34)
                    : theme.colorScheme.outline,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              image.pushedToRegistry ? '已推送 registry' : '仅本地',
              style: theme.textTheme.bodySmall?.copyWith(
                color: image.pushedToRegistry
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
          ),
          // 删除本地副本限定「未使用且已推送」（可从 registry 恢复，避免丢失）。
          if (!image.inUse && image.pushedToRegistry)
            TextButton(
              key: Key('delete-local-${image.reference}'),
              onPressed: () => _deleteLocalCopy(image),
              child: const Text('删除本地副本…'),
            ),
        ],
      ),
    );
  }

  Widget _buildContainersCard(ThemeData theme, ProjectDetails details) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('成员容器', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (details.containers.isEmpty)
              Text(
                '该项目暂无成员容器',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              )
            else
              for (final container in details.containers)
                _buildContainerRow(theme, container),
          ],
        ),
      ),
    );
  }

  Widget _buildContainerRow(ThemeData theme, ContainerSnapshotInfo container) {
    final ports = container.publishedPorts.isEmpty
        ? '—'
        : container.publishedPorts
              .map((p) => '${p.hostPort}→${p.containerPort}')
              .join(', ');
    final running = container.state == ContainerState.running;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(width: 22, child: ContainerStateDot(state: container.state)),
          Expanded(
            flex: 3,
            child: Text(
              container.id,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              container.image,
              style: monoTextStyle(context),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(flex: 2, child: Text(ports, style: monoTextStyle(context))),
          SizedBox(
            width: 80,
            child: Text(
              container.createdAt == null
                  ? '—'
                  : formatRelative(container.createdAt!),
              style: theme.textTheme.bodySmall,
            ),
          ),
          // 行内操作：启动/停止 + 日志 + 删除（复用 ContainerService）。
          SizedBox(
            width: 150,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  key: Key('container-toggle-${container.id}'),
                  icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 16),
                  tooltip: running ? '停止' : '启动',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _toggleContainer(container),
                ),
                IconButton(
                  key: Key('container-logs-${container.id}'),
                  icon: const Icon(Icons.article_outlined, size: 16),
                  tooltip: '日志',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showContainerLogs(container),
                ),
                IconButton(
                  key: Key('container-delete-${container.id}'),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  color: theme.colorScheme.error,
                  onPressed: () => _deleteContainer(container),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 启动/停止成员容器。
  Future<void> _toggleContainer(ContainerSnapshotInfo container) async {
    try {
      if (container.state == ContainerState.running) {
        await widget.containerService.stop(container.id);
      } else {
        await widget.containerService.start(container.id);
      }
      unawaited(_refresh());
    } catch (error) {
      _showError(error);
    }
  }

  /// 删除成员容器（确认弹窗；运行中提示强制）。
  Future<void> _deleteContainer(ContainerSnapshotInfo container) async {
    final running = container.state == ContainerState.running;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除容器'),
        content: Text(
          running
              ? '容器 ${container.id} 正在运行，删除将强制停止。确认删除？'
              : '确认删除容器 ${container.id}？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.containerService.delete(container.id, force: running);
      unawaited(_refresh());
    } catch (error) {
      _showError(error);
    }
  }

  /// 查看成员容器日志（弹窗复用 ContainerLogTab）。
  void _showContainerLogs(ContainerSnapshotInfo container) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 640,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '容器日志 ${container.id}',
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ContainerLogTab(
                  service: widget.containerService,
                  containerId: container.id,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReclaimReportCard(ThemeData theme, ProjectReclaimReport report) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('回收报告', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (_lastReclaimAt != null)
                  Text(
                    formatDateTime(_lastReclaimAt!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '已释放 ${formatBytes(report.disk.reclaimedBytes)}',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '执行链路：container prune → image delete → image prune',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            if (report.deletedContainers.isNotEmpty)
              Text(
                '删除容器：${report.deletedContainers.join('、')}',
                style: theme.textTheme.bodySmall,
              ),
            if (report.deletedImages.isNotEmpty)
              Text(
                '删除镜像：${report.deletedImages.join('、')}',
                style: theme.textTheme.bodySmall,
              ),
            for (final retained in report.retainedImages)
              Text(
                '保留 ${retained.reference}（${retained.reason}）',
                style: theme.textTheme.bodySmall,
              ),
            for (final skipped in report.skippedExternalImages)
              Text(
                '跳过 ${skipped.reference}（外部容器引用：${skipped.usedBy.join('、')}）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '删 tag 只释放独占层；最后一个引用删除 + GC 后才真正回收磁盘。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel(ThemeData theme) {
    final statusText = switch (_logState) {
      BuildLogState.running => '进行中',
      BuildLogState.success => '成功',
      BuildLogState.failed => '失败',
      BuildLogState.cancelled => '已取消',
      BuildLogState.closed => '',
    };
    return Container(
      height: 220,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
        color: theme.colorScheme.surfaceContainerLowest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Row(
              children: [
                Text(_logTitle, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: switch (_logState) {
                      BuildLogState.running => theme.colorScheme.primary,
                      BuildLogState.success => const Color(0xFF1D7A34),
                      BuildLogState.failed => theme.colorScheme.error,
                      BuildLogState.cancelled => theme.colorScheme.outline,
                      BuildLogState.closed => null,
                    },
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('build-log-close'),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '关闭',
                  onPressed: () =>
                      setState(() => _logState = BuildLogState.closed),
                ),
              ],
            ),
          ),
          Expanded(
            child: _logLines.isEmpty
                ? Center(
                    child: Text('等待构建输出…', style: theme.textTheme.bodySmall),
                  )
                : ListView(
                    controller: _logScrollController,
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                    children: [
                      for (final line in _logLines)
                        Text(line, style: monoTextStyle(context)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
