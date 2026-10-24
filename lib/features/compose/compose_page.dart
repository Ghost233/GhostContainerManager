/// Compose 页（ui-ia.md D6）：插件检测（缺失→引导）、label 聚合的项目列表、
/// up/down 操作与插件原文输出透传（截断标记）。
///
/// v1 只做 up/down（插件没有 ps/diff/logs）；项目发现走容器 label 聚合，
/// 不依赖插件。
library;

// Controller constructors assign private fields from named parameters.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/compose_service.dart';
import '../../services/errors.dart';
import '../system/readiness_controller.dart';
import '../../app/placeholders.dart';
import '../../app/section_widgets.dart';

/// Compose 页数据状态（页面级 ChangeNotifier）。up/down 参数（文件路径等）
/// 是页面局部 State，不进 controller。
class ComposeController extends ChangeNotifier {
  ComposeController({required ComposeService service}) : _service = service;

  final ComposeService _service;

  ComposePluginStatus? plugin;
  List<ComposeProject> projects = const [];
  ComposeRunResult? lastRun;
  bool loading = false;
  bool running = false;
  GcmException? lastError;

  /// 每次进入/重试都重新探测（升级 container 会清空插件目录，绝不缓存）。
  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    lastError = null;
    notifyListeners();
    try {
      plugin = await _service.detect();
      projects = await _service.listProjects();
    } on GcmException catch (error) {
      lastError = error;
    } catch (error) {
      lastError = GcmException(GcmErrorCode.internal, '未预期的错误', cause: error);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> up({
    required String file,
    String? projectName,
    bool dryRun = false,
  }) => _run(
    () => _service.up(file: file, projectName: projectName, dryRun: dryRun),
  );

  Future<void> down({String? file, String? projectName}) =>
      _run(() => _service.down(file: file, projectName: projectName));

  Future<void> _run(Future<ComposeRunResult> Function() action) async {
    if (running) return;
    running = true;
    lastError = null;
    lastRun = null;
    notifyListeners();
    try {
      lastRun = await action();
      // up/down 改变项目集合，成功后刷新一次。
      projects = await _service.listProjects();
    } on GcmException catch (error) {
      lastError = error;
    } catch (error) {
      lastError = GcmException(GcmErrorCode.internal, '未预期的错误', cause: error);
    } finally {
      running = false;
      notifyListeners();
    }
  }
}

class ComposePage extends StatefulWidget {
  const ComposePage({
    super.key,
    required this.service,
    required this.controller,
    required this.onOpenRuntime,
  });

  final ComposeService service;
  final ReadinessController controller;
  final VoidCallback onOpenRuntime;

  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  late final ComposeController _compose;
  final _fileController = TextEditingController();
  final _projectController = TextEditingController();
  bool _dryRun = false;

  @override
  void initState() {
    super.initState();
    _compose = ComposeController(service: widget.service);
    if (widget.controller.readiness?.ready ?? false) {
      unawaited(_compose.refresh());
    }
  }

  @override
  void dispose() {
    _compose.dispose();
    _fileController.dispose();
    _projectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!(widget.controller.readiness?.ready ?? false)) {
      return PlaceholderSectionPage(
        title: 'Compose 项目',
        controller: widget.controller,
        onOpenRuntime: widget.onOpenRuntime,
      );
    }
    return ListenableBuilder(
      listenable: _compose,
      builder: (context, _) {
        final plugin = _compose.plugin;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Compose 项目',
              subtitle: 'orchard compose 插件（up/down）· 项目按容器 label 聚合',
              loading: _compose.loading,
              onRefresh: _compose.refresh,
            ),
            if (_compose.lastError case final error?)
              SectionErrorBanner(error: error, onRetry: _compose.refresh),
            if (plugin != null && !plugin.installed)
              _PluginMissingBanner(status: plugin, onRetry: _compose.refresh)
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    _ProjectList(projects: _compose.projects),
                    const SizedBox(height: 16),
                    _buildRunCard(context),
                    if (_compose.lastRun case final run?) ...[
                      const SizedBox(height: 16),
                      _OutputCard(result: run),
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRunCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('up / down', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _fileController,
              decoration: const InputDecoration(
                labelText: 'compose 文件绝对路径',
                hintText: '/Users/you/app/compose.yaml',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _projectController,
              decoration: const InputDecoration(
                labelText: '项目名（可选；缺省取文件 name 或目录名）',
                isDense: true,
              ),
            ),
            Row(
              children: [
                Checkbox(
                  value: _dryRun,
                  onChanged: (value) =>
                      setState(() => _dryRun = value ?? false),
                ),
                Text('dry-run（只打印计划，不改动资源）', style: theme.textTheme.bodySmall),
                const Spacer(),
                OutlinedButton(
                  onPressed: _compose.running ? null : _runDown,
                  child: const Text('down'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _compose.running ? null : _runUp,
                  child: Text(_compose.running ? '执行中…' : 'up'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String get _projectOrEmpty => _projectController.text.trim();

  void _runUp() => unawaited(
    _compose.up(
      file: _fileController.text.trim(),
      projectName: _projectOrEmpty.isEmpty ? null : _projectOrEmpty,
      dryRun: _dryRun,
    ),
  );

  void _runDown() => unawaited(
    _compose.down(
      file: _fileController.text.trim().isEmpty
          ? null
          : _fileController.text.trim(),
      projectName: _projectOrEmpty.isEmpty ? null : _projectOrEmpty,
    ),
  );
}

/// 插件缺失引导（每次使用前的官方探测失败时显示）。
class _PluginMissingBanner extends StatelessWidget {
  const _PluginMissingBanner({required this.status, required this.onRetry});

  final ComposePluginStatus status;
  final VoidCallback onRetry;

  static const String installCommand =
      'sudo mkdir -p /usr/local/libexec/container-plugins && '
      'sudo cp container-compose /usr/local/libexec/container-plugins/';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('未检测到 compose 插件', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'container compose 是独立插件，需安装到系统插件目录后使用：',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          installCommand,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'Menlo',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制安装命令',
                        icon: const Icon(Icons.copy, size: 16),
                        onPressed: () => Clipboard.setData(
                          const ClipboardData(text: installCommand),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '注意：升级 container 会清空插件目录，升级后需重新安装。\n'
                    '探测结果：${status.detail}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: onRetry, child: const Text('重新检测')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectList extends StatelessWidget {
  const _ProjectList({required this.projects});

  final List<ComposeProject> projects;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (projects.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '当前没有 Compose 项目（由 com.compose.project label 聚合）',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final project in projects)
          Card(
            child: ExpansionTile(
              title: Text(project.name, style: theme.textTheme.bodyMedium),
              subtitle: Text(
                '${project.runningCount}/${project.services.length} 个服务运行中',
                style: theme.textTheme.bodySmall,
              ),
              children: [
                for (final service in project.services)
                  ListTile(
                    dense: true,
                    title: Text(
                      service.serviceName.isEmpty
                          ? service.containerId
                          : service.serviceName,
                      style: theme.textTheme.bodySmall,
                    ),
                    subtitle: Text(
                      service.containerId,
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: Text(
                      service.state.wireName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: service.state.wireName == 'running'
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 插件输出原样透传（等宽字体 + 截断标记）。
class _OutputCard extends StatelessWidget {
  const _OutputCard({required this.result});

  final ComposeRunResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('插件输出', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  'exit ${result.exitCode}',
                  style: theme.textTheme.bodySmall,
                ),
                if (result.truncated) ...[
                  const SizedBox(width: 8),
                  Text(
                    '（前段已截断）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(8),
              color: theme.colorScheme.surfaceContainerHighest,
              child: SingleChildScrollView(
                child: SelectableText(
                  result.output.isEmpty ? '（无输出）' : result.output,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
