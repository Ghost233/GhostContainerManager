/// 「运行时」页（issue #16 验收 2；ui-ia.md D8）：
/// 状态卡片 + 版本双端 + 安装路径 + 内核状态 + 一键 start/stop
/// （停止需确认并列出运行中容器数）+ 常驻「重新运行引导检查」。
library;

import 'package:flutter/material.dart';

import '../../services/errors.dart';
import '../../services/system_service.dart';
import 'readiness_controller.dart';

class RuntimePage extends StatelessWidget {
  const RuntimePage({super.key, required this.controller});

  final ReadinessController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final readiness = controller.readiness;
        if (readiness == null && controller.action == SystemAction.checking) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                Text('运行时', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(width: 12),
                if (controller.debugBypassUsed)
                  const Tooltip(
                    message:
                        'GCM_DEBUG_ALLOW_UNSUPPORTED_RUNTIME 已生效，'
                        '版本门禁被跳过（仅 debug 构建）',
                    child: Chip(label: Text('debug 绕行')),
                  ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: controller.busy ? null : controller.refresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重新运行引导检查'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (controller.lastError != null) ...[
              _ErrorBanner(error: controller.lastError!),
              const SizedBox(height: 16),
            ],
            if (readiness != null) ...[
              _StatusCard(controller: controller, readiness: readiness),
              const SizedBox(height: 16),
              _ActionRow(controller: controller, readiness: readiness),
            ],
          ],
        );
      },
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});

  final GcmException error;

  @override
  Widget build(BuildContext context) {
    final message = error.hint != null
        ? '${error.message}\n${error.hint}'
        : error.message;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              size: 16,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller, required this.readiness});

  final ReadinessController controller;
  final ReadinessResult readiness;

  @override
  Widget build(BuildContext context) {
    final data = controller.statusData;
    final theme = Theme.of(context);
    final running = data?.running ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.check_circle : Icons.cancel_outlined,
                  size: 16,
                  color: running ? Colors.green : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Text(
                  running ? '服务运行中' : _levelLabel(readiness.level),
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _row(
              context,
              '版本',
              'CLI ${readiness.cliVersion ?? '—'} / '
                  'apiserver ${readiness.apiServerVersion ?? '—'}',
            ),
            _row(context, '安装路径', readiness.installPath ?? '未找到'),
            _row(context, '内核', switch (readiness.level) {
              ReadinessLevel.ready => '默认内核已就位',
              ReadinessLevel.kernelMissing => '缺失（可一键安装推荐内核）',
              _ => '未检测',
            }),
            if (data?.resources != null)
              _row(
                context,
                '资源',
                '容器 ${data!.resources!.containersRunning} 运行中 / '
                    '${data.resources!.containersTotal} 共，'
                    '镜像 ${data.resources!.images} 个',
              ),
            if (data?.appRoot != null) _row(context, '数据目录', data!.appRoot!),
            if (readiness.detail != null) ...[
              const SizedBox(height: 8),
              Text(readiness.detail!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  String _levelLabel(ReadinessLevel level) => switch (level) {
    ReadinessLevel.notInstalled => '未安装',
    ReadinessLevel.versionTooLow => '版本过低',
    ReadinessLevel.unsupportedMajor => '大版本不兼容',
    ReadinessLevel.serviceNotRunning => '服务未运行',
    ReadinessLevel.kernelMissing => '服务运行中（内核缺失）',
    ReadinessLevel.ready => '就绪',
  };

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.controller, required this.readiness});

  final ReadinessController controller;
  final ReadinessResult readiness;

  @override
  Widget build(BuildContext context) {
    final running = controller.statusData?.running ?? false;
    final busy = controller.busy;

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        if (!running && readiness.level != ReadinessLevel.notInstalled)
          FilledButton.icon(
            onPressed: busy ? null : controller.startRuntime,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(
              controller.action == SystemAction.starting
                  ? '正在启动（如需内核将一并安装）…'
                  : '启动运行时',
            ),
          ),
        if (running)
          FilledButton.tonalIcon(
            onPressed: busy ? null : () => _confirmStop(context),
            icon: const Icon(Icons.stop, size: 16),
            label: Text(
              controller.action == SystemAction.stopping ? '正在停止…' : '停止运行时',
            ),
          ),
        if (readiness.level == ReadinessLevel.kernelMissing)
          FilledButton.icon(
            onPressed: busy ? null : controller.installKernel,
            icon: const Icon(Icons.download, size: 16),
            label: Text(
              controller.action == SystemAction.installingKernel
                  ? '正在安装内核…'
                  : '安装推荐内核',
            ),
          ),
      ],
    );
  }

  Future<void> _confirmStop(BuildContext context) async {
    final runningCount =
        controller.statusData?.resources?.containersRunning ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止运行时'),
        content: Text(
          '停止后所有容器将暂停运行'
          '${runningCount > 0 ? '（当前 $runningCount 个容器运行中）' : ''}'
          '。MCP 管理工具在运行时就绪前将返回 runtime_unavailable。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('停止运行时'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.stopRuntime();
    }
  }
}
