/// 项目页弹窗：一键回收确认（480，force 默认勾选，将删除/将跳过分组）
/// 与「删除本地副本」三选弹窗（取消/仅删除/归档并删除）。
library;

import 'package:flutter/material.dart';

import '../../services/project_service.dart';

/// 三选删除弹窗的选择。
enum DeleteLocalChoice { deleteOnly, archiveAndDelete }

/// 一键回收确认弹窗的返回：confirmed=确认执行，force=强制删除运行中容器。
typedef ReclaimConfirmation = ({bool confirmed, bool force});

/// 一键回收确认弹窗。返回 {confirmed:true, force} 确认执行，null=取消。
Future<ReclaimConfirmation?> showReclaimDialog(
  BuildContext context, {
  required String project,
  required ProjectReclaimReport preview,
}) {
  return showDialog<ReclaimConfirmation>(
    context: context,
    builder: (context) => _ReclaimDialog(project: project, preview: preview),
  );
}

class _ReclaimDialog extends StatefulWidget {
  const _ReclaimDialog({required this.project, required this.preview});

  final String project;
  final ProjectReclaimReport preview;

  @override
  State<_ReclaimDialog> createState() => _ReclaimDialogState();
}

class _ReclaimDialogState extends State<_ReclaimDialog> {
  /// 项目自动化回收分叉：force 默认勾选（终轮拍板）。
  bool _force = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.preview;
    final willDelete = <String>[
      ...preview.deletedContainers.map((id) => '容器 $id'),
      ...preview.deletedImages.map((ref) => '镜像 $ref'),
    ];
    final willSkip = <String>[
      for (final retained in preview.retainedImages)
        '${retained.reference}（${retained.reason}）',
      for (final skipped in preview.skippedExternalImages)
        '${skipped.reference}（外部容器引用：${skipped.usedBy.join('、')}）',
    ];
    return AlertDialog(
      title: Text('一键回收项目「${widget.project}」'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '将停止并删除项目容器，再删除未被引用的项目镜像。'
              '事实以 CLI 结果为准，完成后显示回收报告。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (willDelete.isNotEmpty) ...[
              Text('将删除', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final item in willDelete)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 2),
                  child: Text(item, style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 8),
            ],
            if (willSkip.isNotEmpty) ...[
              Text('将跳过', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final item in willSkip)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 2),
                  child: Text(
                    item,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Checkbox(
                  key: const Key('reclaim-force'),
                  value: _force,
                  onChanged: (value) => setState(() => _force = value ?? true),
                ),
                Expanded(
                  child: Text(
                    '强制删除运行中容器（项目回收默认勾选；'
                    '手动单删镜像默认不勾选）',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () =>
              Navigator.of(context).pop((confirmed: true, force: _force)),
          child: const Text('回收并显示报告'),
        ),
      ],
    );
  }
}

/// 「删除本地副本」三选弹窗。返回 null=取消。
Future<DeleteLocalChoice?> showDeleteLocalCopyDialog(
  BuildContext context, {
  required String reference,
}) {
  return showDialog<DeleteLocalChoice>(
    context: context,
    builder: (context) => _DeleteLocalCopyDialog(reference: reference),
  );
}

class _DeleteLocalCopyDialog extends StatelessWidget {
  const _DeleteLocalCopyDialog({required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('删除本地副本'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(reference, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text(
              '仅删除：直接删除本地镜像 tag。已推送到本地 registry 的镜像，'
              '删除后恢复依赖 registry 容器与数据卷存活（循环依赖风险）。\n'
              '归档并删除：先推送到本地 registry 再删本地副本。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: () =>
              Navigator.of(context).pop(DeleteLocalChoice.deleteOnly),
          child: const Text('仅删除'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(DeleteLocalChoice.archiveAndDelete),
          child: const Text('归档并删除'),
        ),
      ],
    );
  }
}
