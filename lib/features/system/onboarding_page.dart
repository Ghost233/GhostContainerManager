import 'dart:async';

import 'package:flutter/material.dart';

import 'readiness_controller.dart';

const String kContainerReleaseUrl = 'https://docs.docker.com/engine/install/';

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({
    super.key,
    required this.controller,
    required this.onSkipToSettings,
  });
  final ReadinessController controller;
  final VoidCallback onSkipToSettings;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '配置 Docker 连接',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            const Text(
              '安装 Docker CLI 与标准 Docker Compose，并配置可用的 Docker context 或 DOCKER_HOST。底层引擎不限。',
            ),
            SelectableText(kContainerReleaseUrl),
            if (controller.readiness?.detail case final detail?) Text(detail),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: controller.busy
                  ? null
                  : () => unawaited(controller.refresh()),
              child: const Text('重新检查'),
            ),
            TextButton(
              onPressed: onSkipToSettings,
              child: const Text('跳过并仅查看设置'),
            ),
          ],
        ),
      ),
    ),
  );
}
