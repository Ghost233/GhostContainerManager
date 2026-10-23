/// Blocking onboarding wizard for externally-unfixable readiness failures
/// (docs/spec/onboarding.md §4 方案 C): notInstalled / versionTooLow /
/// unsupportedMajor replace the main UI; serviceNotRunning / kernelMissing
/// use the degraded shell instead (see app_shell.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/system_service.dart';
import 'readiness_controller.dart';

/// Official signed-pkg download page (onboarding.md §2.1: 唯一官方文档化途径).
const String kContainerReleaseUrl =
    'https://github.com/apple/container/releases';

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({
    super.key,
    required this.controller,
    required this.onSkipToSettings,
  });

  final ReadinessController controller;

  /// 「跳过并仅查看设置」出口（方案 C：不强制退出 app）。
  final VoidCallback onSkipToSettings;

  @override
  Widget build(BuildContext context) {
    final readiness = controller.readiness;
    final level = readiness?.level ?? ReadinessLevel.notInstalled;
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                switch (level) {
                  ReadinessLevel.notInstalled => Icons.download_outlined,
                  ReadinessLevel.versionTooLow => Icons.system_update_alt,
                  _ => Icons.error_outline,
                },
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                _title(level),
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              if (readiness?.detail case final detail?)
                Text(
                  detail,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              if (readiness?.cliVersion case final cliVersion?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '检测到 CLI 版本 $cliVersion'
                    '${switch (readiness?.apiServerVersion) {
                      final v? => '，apiserver 版本 $v',
                      null => '',
                    }}'
                    '；需要 ≥ ${SystemService.anchorVersion}（锁定大版本 ${SystemService.supportedMajor}.x）',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 24),
              ..._guidance(context, level),
              const SizedBox(height: 24),
              if (controller.lastError != null) ...[
                Text(
                  '上次操作失败：${controller.lastError!.message}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
              ],
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  ..._actions(context, level),
                  OutlinedButton.icon(
                    onPressed: controller.busy
                        ? null
                        : () => unawaited(controller.refresh()),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(
                      controller.action == SystemAction.checking
                          ? '正在检测…'
                          : '重新检测',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
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

  String _title(ReadinessLevel level) => switch (level) {
    ReadinessLevel.notInstalled => '未安装 Apple container 运行时',
    ReadinessLevel.versionTooLow => '运行时版本过低',
    ReadinessLevel.unsupportedMajor => '运行时大版本不兼容',
    _ => '引导检查',
  };

  List<Widget> _guidance(BuildContext context, ReadinessLevel level) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return switch (level) {
      ReadinessLevel.notInstalled => [
        Text('安装步骤：', style: style?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          '1. 从官方发布页下载签名安装包（container-1.6.0-installer-signed.pkg）\n'
          '2. 双击安装包，按提示输入管理员密码（安装到 /usr/local）\n'
          '3. 回到本页点击「重新检测」',
          style: style,
        ),
        const SizedBox(height: 12),
        Text(
          '社区途径（非官方、版本可能滞后）：brew install container',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
      ReadinessLevel.versionTooLow => [
        Text(
          'pkg 安装：运行 /usr/local/bin/update-container.sh\n'
          'Homebrew 安装：brew upgrade container\n'
          '升级后请执行 container system restart 使服务切换到新版本。',
          style: style,
        ),
      ],
      ReadinessLevel.unsupportedMajor => [
        Text(
          '本应用支持 Apple container 1.x（≥ 1.6.0）。检测到的大版本超出支持范围，'
          '请回退运行时版本，或等待应用更新。',
          style: style,
        ),
      ],
      _ => const [],
    };
  }

  List<Widget> _actions(BuildContext context, ReadinessLevel level) {
    Future<void> copy(String label, String text) async {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已复制$label')));
      }
    }

    return switch (level) {
      ReadinessLevel.notInstalled => [
        FilledButton.icon(
          onPressed: () => unawaited(copy('下载页地址', kContainerReleaseUrl)),
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('复制官方下载页地址'),
        ),
        OutlinedButton.icon(
          onPressed: () => unawaited(copy('brew 命令', 'brew install container')),
          icon: const Icon(Icons.terminal, size: 16),
          label: const Text('复制 brew 安装命令'),
        ),
      ],
      ReadinessLevel.versionTooLow => [
        OutlinedButton.icon(
          onPressed: () => unawaited(
            copy('升级命令', 'sudo /usr/local/bin/update-container.sh'),
          ),
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('复制 pkg 升级命令'),
        ),
        OutlinedButton.icon(
          onPressed: () =>
              unawaited(copy('brew 升级命令', 'brew upgrade container')),
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('复制 brew 升级命令'),
        ),
      ],
      _ => const [],
    };
  }
}
