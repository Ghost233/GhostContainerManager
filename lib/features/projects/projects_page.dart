/// 项目页（#23 / D11 终轮版）：项目列表 + 项目详情 + 一键回收 + 三选删除。
///
/// 数据源 = ProjectService（label 权威）+ ContainerService（成员容器行）。
/// 磁盘占用 = 内存快照 + 用户手动刷新（终轮拍板：不做自动校准/实时刷新）。
/// registry 不设状态区（全局单例）；循环依赖提示在删除/推送确认文案里。
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app/placeholders.dart';
import '../../services/container_service.dart';
import '../../services/image_footprint_service.dart';
import '../../services/image_service.dart';
import '../../services/project_service.dart';
import '../../ui/text.dart';
import '../containers/containers_page.dart' show AppOwnedTag;
import '../system/readiness_controller.dart';
import 'project_detail.dart';

/// 项目列表页：工具栏（搜索/磁盘快照刷新/新建）+ 表头 + 行列表。
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({
    super.key,
    required this.service,
    required this.containerService,
    required this.imageService,
    required this.controller,
    this.footprintService,
    required this.onOpenRuntime,
  });

  final ProjectService service;
  final ContainerService containerService;
  final ImageService imageService;
  final ReadinessController controller;

  /// Optional seam for widget tests; production owns one shared cache service.
  final ImageFootprintService? footprintService;

  /// 「打开引导检查」次按钮（跳到运行时页），与占位页语义一致。
  final VoidCallback onOpenRuntime;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  List<ProjectSummary> _projects = const [];
  bool _loading = true;
  Object? _error;
  String _search = '';
  String? _selectedProject;
  late final ImageFootprintService _footprintService;

  /// 磁盘占用快照（bytes）：仅手动刷新更新（终轮拍板，无自动校准）。
  int? _diskBytes;
  bool _diskLoading = false;

  /// 项目级磁盘占用（该行镜像 sizeBytes 求和）：project → bytes。
  final Map<String, int> _projectDiskBytes = {};

  bool get _ready => widget.controller.readiness?.ready ?? false;

  @override
  void initState() {
    super.initState();
    _footprintService = widget.footprintService ?? ImageFootprintService();
    widget.controller.addListener(_syncWithReadiness);
    _syncWithReadiness();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncWithReadiness);
    super.dispose();
  }

  void _syncWithReadiness() {
    if (_ready && _loading && _projects.isEmpty && _error == null) {
      _refresh();
    }
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final projects = await widget.service.listProjects();
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _loading = false;
        _error = null;
        if (_selectedProject != null &&
            !projects.any((p) => p.project == _selectedProject)) {
          _selectedProject = null;
        }
      });
      // 首次加载时取一次磁盘快照（之后只随手动刷新更新）。
      if (_diskBytes == null && !_diskLoading) {
        unawaited(_refreshDiskSnapshot());
      }
      unawaited(_refreshProjectDiskBytes(projects));
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _refreshDiskSnapshot() async {
    if (_diskLoading) return;
    setState(() => _diskLoading = true);
    try {
      // 全局磁盘快照：独立 df 查询（不占项目锁，替换 reclaim 借道）。
      final bytes = await widget.service.diskUsageBytes();
      if (!mounted) return;
      setState(() => _diskBytes = bytes);
    } catch (_) {
      // 磁盘快照失败不阻塞列表；保持旧值或空。
    } finally {
      if (mounted) setState(() => _diskLoading = false);
    }
  }

  List<ProjectSummary> get _filtered {
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return _projects;
    return _projects
        .where((p) => p.project.toLowerCase().contains(query))
        .toList(growable: false);
  }

  /// 项目级磁盘占用（实占）：镜像层 blob 实际块 + 成员容器目录实际占用。
  /// 逐项目串行计算（项目数少，stat/du 成本低）。
  Future<void> _refreshProjectDiskBytes(List<ProjectSummary> projects) async {
    final root =
        widget.controller.statusData?.appRoot ??
        ImageFootprintService.defaultAppRoot();
    for (final summary in projects) {
      try {
        final details = await widget.service.getProject(
          project: summary.project,
        );
        if (!mounted) return;
        var total = 0;
        for (final image in details.images) {
          final digest = image.digest;
          if (digest == null) {
            total += image.sizeBytes ?? 0;
            continue;
          }
          total += await _footprintService.layerDiskBytes(
            digest: digest,
            appRoot: widget.controller.statusData?.appRoot,
          );
        }
        for (final container in details.containers) {
          total += await _footprintService.containerDirectoryBytes(
            container.id,
            appRoot: root,
          );
        }
        if (!mounted) return;
        setState(() => _projectDiskBytes[summary.project] = total);
      } catch (_) {
        // 单项目求和失败不阻塞列表；保持缺省。
      }
    }
  }

  /// 从目录新建项目：选目录 → initProject（prefix 读 ghostcontainer.toml）→ 刷新。
  Future<void> _initProject() async {
    final path = await getDirectoryPath(confirmButtonText: '选择项目目录');
    if (path == null || !mounted) return;
    try {
      final project = await widget.service.initProject(path: path);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已创建项目 ${project.prefix}')));
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('新建项目失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return PlaceholderSectionPage(
        title: '项目',
        controller: widget.controller,
        onOpenRuntime: widget.onOpenRuntime,
      );
    }
    final selected = _selectedProject;
    if (selected != null) {
      return ProjectDetailView(
        key: ValueKey(selected),
        service: widget.service,
        containerService: widget.containerService,
        imageService: widget.imageService,
        footprintService: _footprintService,
        appRoot: widget.controller.statusData?.appRoot,
        project: selected,
        onBack: () => setState(() => _selectedProject = null),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: SizedBox(
              height: 32,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索项目',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(),
                ),
                style: theme.textTheme.bodySmall,
                onChanged: (value) => setState(() => _search = value),
              ),
            ),
          ),
          const Spacer(),
          // 全局磁盘快照（df）：工具栏单一展示位（第 7 条）。
          if (_diskBytes != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '磁盘 ${formatBytes(_diskBytes!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          OutlinedButton.icon(
            key: const Key('refresh-disk-snapshot'),
            onPressed: _diskLoading ? null : _refreshDiskSnapshot,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('⟳ 刷新磁盘快照'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('init-project-button'),
            onPressed: _initProject,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('＋ 从目录新建项目…'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _projects.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _projects.isEmpty) {
      return _ErrorState(error: _error!, onRetry: _refresh);
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _search.isEmpty
          ? _EmptyState(onInit: _initProject)
          : Center(
              child: Text(
                '没有匹配「$_search」的项目',
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
            itemBuilder: (context, index) => _ProjectRow(
              summary: rows[index],
              diskBytes: _projectDiskBytes[rows[index].project],
              onTap: () =>
                  setState(() => _selectedProject = rows[index].project),
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
          Expanded(flex: 3, child: Text('名称', style: style)),
          SizedBox(width: 90, child: Text('镜像数', style: style)),
          SizedBox(width: 110, child: Text('运行中容器', style: style)),
          SizedBox(
            width: 90,
            child: Tooltip(
              message:
                  '实占合计：镜像层 blob 的磁盘块 + 该项目容器的运行时目录（含 '
                  'initfs 系统盘、kernel 与稀疏 rootfs 的真实占用）。',
              child: Text('实占', style: style),
            ),
          ),
          SizedBox(width: 120, child: Text('最近构建', style: style)),
        ],
      ),
    );
  }
}

/// 项目行：名称（副行 label + 本应用创建标记）/ 镜像数 / 运行中容器 / 磁盘快照 / 最近构建。
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.summary,
    required this.diskBytes,
    required this.onTap,
  });

  final ProjectSummary summary;
  final int? diskBytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          summary.project,
                          style: theme.textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const AppOwnedTag(),
                    ],
                  ),
                  Text(
                    '$projectLabel=${summary.project}',
                    style: monoTextStyle(
                      context,
                    )?.copyWith(color: theme.colorScheme.outline, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                '${summary.images.length} 个镜像',
                style: theme.textTheme.bodySmall,
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(
                '${summary.containers} 个容器',
                style: theme.textTheme.bodySmall,
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                diskBytes == null ? '—' : formatBytes(diskBytes!),
                style: theme.textTheme.bodySmall,
              ),
            ),
            SizedBox(
              width: 120,
              child: Text(
                summary.lastBuildAt == null
                    ? '—'
                    : formatRelative(summary.lastBuildAt!),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onInit});

  final VoidCallback onInit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('暂无项目', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            '从含 ghostcontainer.toml 的目录初始化第一个项目',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onInit,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('＋ 从目录新建项目…'),
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
          Text('项目列表加载失败', style: theme.textTheme.bodyMedium),
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
