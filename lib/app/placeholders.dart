/// 数据区占位页（T1b 只实现运行时/设置两页，其余侧栏项用占位）。
///
/// 按 ui-ia.md D8：运行时未就绪是全局态——占位页在非就绪时显示统一的
/// 「运行时未启动」占位（主按钮「启动运行时」+ 次按钮「打开引导检查」），
/// 就绪后显示各资源页的空态占位（真实列表由后续任务实现）。
library;

import 'package:flutter/material.dart';

import '../../services/system_service.dart';
import '../features/system/readiness_controller.dart';

class PlaceholderSectionPage extends StatelessWidget {
  const PlaceholderSectionPage({
    super.key,
    required this.title,
    required this.controller,
    required this.onOpenRuntime,
  });

  final String title;
  final ReadinessController controller;

  /// 「打开引导检查」次按钮：跳到「运行时」页。
  final VoidCallback onOpenRuntime;

  @override
  Widget build(BuildContext context) {
    final ready = controller.readiness?.ready ?? false;
    final level = controller.readiness?.level;
    final selfFixable =
        level == ReadinessLevel.serviceNotRunning ||
        level == ReadinessLevel.kernelMissing;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ready ? Icons.inbox_outlined : Icons.cloud_off_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            ready ? '$title：暂无内容' : '运行时未就绪，$title暂不可用',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (!ready && level != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.readiness?.detail ?? '',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                if (selfFixable)
                  FilledButton(
                    onPressed: controller.busy
                        ? null
                        : (level == ReadinessLevel.kernelMissing
                              ? controller.installKernel
                              : controller.startRuntime),
                    child: Text(
                      level == ReadinessLevel.kernelMissing
                          ? '安装推荐内核'
                          : '启动运行时',
                    ),
                  ),
                OutlinedButton(
                  onPressed: onOpenRuntime,
                  child: const Text('打开引导检查'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
