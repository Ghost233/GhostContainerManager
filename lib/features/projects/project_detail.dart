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
import '../containers/containers_page.dart';
import 'project_dialogs.dart';

/// 构建日志面板状态。
enum BuildLogState { closed, running, success, failed }

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

  /// 构建日志面板。
  BuildLogState _logState = BuildLogState.closed;
  String _logTitle = '';
  final List<String> _logLines = [];
  String? _lastFailureLogPath;
  int _buildSequence = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
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
    final pattern = RegExp('^${widget.project}-go(\\d+):latest\$');
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
    }
  }

  Future<void> _showLastFailureLog() async {
    final path = _lastFailureLogPath;
    if (path == null) return;
    String content;
    try {
      content = await File(path).readAsString();
    } catch (error) {
      content = '读取失败日志失败：$error';
    }
    if (!mounted) return;
    setState(() {
      _logState = BuildLogState.failed;
      _logTitle = '上次失败日志';
      _logLines
        ..clear()
        ..addAll(content.split('\n').where((line) => line.isNotEmpty));
    });
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
    final confirmed = await showReclaimDialog(
      context,
      project: widget.project,
      preview: preview,
    );
    if (confirmed != true || !mounted) return;
    try {
      final report = await widget.service.reclaimProject(
        project: widget.project,
      );
      if (!mounted) return;
      setState(() => _lastReclaim = report);
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
          if (!image.inUse)
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
        ],
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
            Text('回收报告', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '已释放 ${formatBytes(report.disk.reclaimedBytes)}',
              style: theme.textTheme.headlineSmall,
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
