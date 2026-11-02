import 'dart:async';

import 'package:flutter/material.dart';

import 'readiness_controller.dart';

class RuntimePage extends StatelessWidget {
  const RuntimePage({super.key, required this.controller});
  final ReadinessController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final status = controller.statusData;
      final readiness = controller.readiness;
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Docker 运行时', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Text(readiness?.ready == true ? 'Docker 端点已连接' : 'Docker 端点未就绪'),
          Text(
            'CLI ${readiness?.cliVersion ?? '—'} / Engine ${readiness?.apiServerVersion ?? '—'}',
          ),
          Text(readiness?.installPath ?? '未找到 Docker CLI'),
          if (status?.resources case final resources?)
            Text(
              '容器 ${resources.containersRunning} 运行中 / ${resources.containersTotal} 共，镜像 ${resources.images} 个',
            ),
          const Text(
            '沿用当前 Docker context、DOCKER_HOST 和 TLS 配置。引擎启停与数据目录由引擎自身管理。',
          ),
          if (readiness?.detail case final detail?) Text(detail),
          if (controller.lastError case final error?) Text(error.message),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => unawaited(controller.refresh()),
              icon: const Icon(Icons.refresh),
              label: const Text('重新检查连接'),
            ),
          ),
        ],
      );
    },
  );
}
