/// 镜像页（#20 / ui-ia.md 通用约束）：列表 + 检查器详情 + 拉取对话框。
///
/// 数据源 = ImageService（T5）：镜像域无轮询需求，页面就绪时拉一次，
/// 刷新/拉取/删除后显式重载。运行时未就绪遵循 D8 全局态，复用统一占位页。
///
/// 验收对应：列表 reference/大小/创建时间 + dangling 标记（验收 1）、
/// inspect 配置摘要详情（验收 1）、拉取进度实时可取消（验收 2）、
/// 删除确认与错误呈现（验收 3）。
library;

import 'dart:async';

// Flutter 的 painting 库自带同名 ImageInfo，隐藏以使用镜像域模型。
import 'package:flutter/material.dart' hide ImageInfo;

import '../../app/placeholders.dart';
import '../../services/errors.dart';
import '../../services/image_models.dart';
import '../../services/image_service.dart';
import '../system/readiness_controller.dart';

/// 镜像列表页：工具栏（搜索/计数/拉取/刷新）+ 行列表。
class ImagesPage extends StatefulWidget {
  const ImagesPage({
    super.key,
    required this.service,
    required this.controller,
    required this.onOpenRuntime,
  });

  final ImageService service;
  final ReadinessController controller;

  /// 「打开引导检查」次按钮（跳到运行时页），与占位页语义一致。
  final VoidCallback onOpenRuntime;

  @override
  State<ImagesPage> createState() => _ImagesPageState();
}

class _ImagesPageState extends State<ImagesPage> {
  List<ImageInfo> _images = const [];
  bool _loading = true;
  Object? _error;
  String _search = '';
  String? _selectedReference;

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
    super.dispose();
  }

  /// 就绪状态变化时接/断数据（D8：未就绪是全局态）。
  void _syncWithReadiness() {
    if (_ready && _loading && _error == null) {
      unawaited(_refresh());
    }
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final images = await widget.service.listImages();
      if (!mounted) return;
      setState(() {
        _images = images;
        _loading = false;
        _error = null;
        // 选中镜像被删除时退回列表。
        if (_selectedReference != null &&
            !images.any((i) => i.reference == _selectedReference)) {
          _selectedReference = null;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  List<ImageInfo> get _filtered {
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return _images;
    return _images
        .where((i) => i.displayReference.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _openPullDialog() async {
    final pulled = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PullDialog(service: widget.service),
    );
    if (pulled == true) await _refresh();
  }

  Future<void> _confirmDelete(ImageInfo image) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // ui-ia.md 删除确认弹窗 480 宽。
        content: SizedBox(
          width: 480,
          child: Text(
            '删除镜像 ${image.displayReference}？\n'
            '此操作移除该 tag；未被引用的层由运行时回收。',
          ),
        ),
        title: const Text('删除镜像'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.service.delete(image.reference);
      await _refresh();
    } on GcmException catch (e) {
      if (!mounted) return;
      // 被容器引用等失败以对话框呈现完整错误码与提示（验收 3）。
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除失败'),
          content: SizedBox(
            width: 480,
            child: Text(
              '${e.message}\n错误码：${e.code.wireName}'
              '${e.hint != null ? '\n${e.hint}' : ''}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return PlaceholderSectionPage(
        title: '镜像',
        controller: widget.controller,
        onOpenRuntime: widget.onOpenRuntime,
      );
    }
    final selected = _selectedReference;
    if (selected != null) {
      return _ImageDetailView(
        key: ValueKey(selected),
        service: widget.service,
        reference: selected,
        onBack: () => setState(() => _selectedReference = null),
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
    final dangling = _images.where((i) => i.isDangling).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          SizedBox(
            width: 280,
            height: 32,
            child: TextField(
              decoration: const InputDecoration(
                hintText: '搜索镜像',
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
            '共 ${_images.length} 个镜像（悬空 $dangling）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const Spacer(),
          FilledButton.tonalIcon(
            onPressed: _openPullDialog,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('拉取镜像'),
          ),
          const SizedBox(width: 8),
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
    if (_loading && _images.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _images.isEmpty) {
      return _ErrorState(error: _error!, onRetry: _refresh);
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return _search.isEmpty
          ? _EmptyState(onPull: _openPullDialog)
          : Center(child: Text('没有匹配「$_search」的镜像'));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final image = rows[index];
        return _ImageRow(
          image: image,
          onTap: () => setState(() => _selectedReference = image.reference),
          onDelete: () => _confirmDelete(image),
        );
      },
    );
  }
}

class _ImageRow extends StatelessWidget {
  const _ImageRow({
    required this.image,
    required this.onTap,
    required this.onDelete,
  });

  final ImageInfo image;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        title: Row(
          children: [
            Flexible(
              child: Text(
                image.displayReference,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (image.isDangling) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: '悬空镜像：未被任何容器引用，可安全删除',
                child: Chip(
                  label: const Text('悬空'),
                  labelStyle: theme.textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          [
            formatImageSize(image.sizeBytes),
            if (image.createdAt != null) _formatDate(image.createdAt!),
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        trailing: IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: onDelete,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPull});

  final VoidCallback onPull;

  @override
  Widget build(BuildContext context) {
    // ui-ia.md 四态模板：空态 = 图标 + 一句话 + 主操作。
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.layers_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('暂无镜像，拉取一个开始使用', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onPull,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('拉取镜像'),
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
    final message = switch (error) {
      GcmException e => '${e.message}（${e.code.wireName}）',
      _ => '$error',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 40,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 检查器详情：image_inspect 的配置摘要（验收 1）。
class _ImageDetailView extends StatefulWidget {
  const _ImageDetailView({
    super.key,
    required this.service,
    required this.reference,
    required this.onBack,
  });

  final ImageService service;
  final String reference;
  final VoidCallback onBack;

  @override
  State<_ImageDetailView> createState() => _ImageDetailViewState();
}

class _ImageDetailViewState extends State<_ImageDetailView> {
  ImageInspection? _inspection;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final inspection = await widget.service.inspect(widget.reference);
      if (mounted) setState(() => _inspection = inspection);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('返回镜像列表'),
          ),
          const SizedBox(height: 8),
          Text(widget.reference, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          Expanded(
            child: switch ((_inspection, _error)) {
              (_, final Object error) => _ErrorState(
                error: error,
                onRetry: () {
                  setState(() => _error = null);
                  unawaited(_load());
                },
              ),
              (null, null) => const Center(child: CircularProgressIndicator()),
              (final ImageInspection inspection, null) => ListView(
                children: [
                  _kv('摘要', inspection.digest ?? '-'),
                  _kv('大小', formatImageSize(inspection.sizeBytes)),
                  _kv('层数', '${inspection.layers}'),
                  _kv('平台', inspection.platforms.join('、')),
                  _section(theme, '入口命令'),
                  Text(
                    (inspection.entrypoint + inspection.cmd).join(' '),
                    style: theme.textTheme.bodySmall,
                  ),
                  _section(theme, '暴露端口'),
                  Text(
                    inspection.exposedPorts.isEmpty
                        ? '-'
                        : inspection.exposedPorts.join('、'),
                    style: theme.textTheme.bodySmall,
                  ),
                  _section(theme, '环境变量'),
                  for (final env in inspection.env)
                    Text(env, style: theme.textTheme.bodySmall),
                  if (inspection.env.isEmpty)
                    Text('-', style: theme.textTheme.bodySmall),
                  _section(theme, '标签'),
                  for (final entry in inspection.labels.entries)
                    Text(
                      '${entry.key}=${entry.value}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (inspection.labels.isEmpty)
                    Text('-', style: theme.textTheme.bodySmall),
                ],
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Flexible(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(title, style: theme.textTheme.titleSmall),
  );
}

/// 拉取对话框（验收 2）：输入引用 → 进度条实时更新 → 可取消。
class _PullDialog extends StatefulWidget {
  const _PullDialog({required this.service});

  final ImageService service;

  @override
  State<_PullDialog> createState() => _PullDialogState();
}

class _PullDialogState extends State<_PullDialog> {
  final _referenceController = TextEditingController();
  final _platformController = TextEditingController();

  bool _pulling = false;
  ImagePullProgress? _progress;
  String? _error;
  String? _pullId;

  @override
  void dispose() {
    _referenceController.dispose();
    _platformController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final reference = _referenceController.text.trim();
    if (reference.isEmpty) return;
    final platform = _platformController.text.trim();
    final pullId = widget.service.newPullId();
    setState(() {
      _pulling = true;
      _error = null;
      _pullId = pullId;
    });
    final outcome = await widget.service.pull(
      reference: reference,
      platform: platform.isEmpty ? null : platform,
      pullId: pullId,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    switch (outcome) {
      case ImagePullCompleted():
        Navigator.of(context).pop(true);
      case ImagePullCancelled():
        Navigator.of(context).pop(false);
    }
  }

  Future<void> _cancel() async {
    final pullId = _pullId;
    if (pullId != null) await widget.service.cancelPull(pullId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _progress;
    return AlertDialog(
      title: const Text('拉取镜像'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_pulling) ...[
              TextField(
                controller: _referenceController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '镜像引用',
                  hintText: 'name:tag（如 alpine:3.19，缺省 :latest）',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _start(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _platformController,
                decoration: const InputDecoration(
                  labelText: '平台（可选）',
                  hintText: 'linux/arm64，缺省为本机架构',
                  border: OutlineInputBorder(),
                ),
              ),
            ] else ...[
              LinearProgressIndicator(value: progress?.fraction),
              const SizedBox(height: 8),
              Text(
                progress == null
                    ? '正在连接镜像仓库…'
                    : '${progress.description ?? '下载中'} · '
                          '${formatImageSize(progress.completedBytes)}'
                          '${progress.totalBytes != null ? ' / ${formatImageSize(progress.totalBytes!)}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_pulling)
          TextButton(onPressed: _cancel, child: const Text('取消拉取'))
        else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: _start, child: const Text('拉取')),
        ],
      ],
    );
  }
}

/// 镜像大小的人类可读格式（B/KB/MB/GB，一位小数）。
String formatImageSize(int? bytes) {
  if (bytes == null) return '-';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

String _formatDate(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-'
    '${time.day.toString().padLeft(2, '0')}';
