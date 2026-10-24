import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/system/onboarding_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/system_service.dart';

Future<(ReadinessController, bool Function())> _pumpOnboarding(
  WidgetTester tester,
  FakeContainerBridge fake,
) async {
  final controller = ReadinessController(
    systemService: SystemService(bridge: fake),
    bridge: fake,
  );
  await controller.refresh();
  var skipped = false;
  await tester.pumpWidget(
    MaterialApp(
      home: OnboardingPage(
        controller: controller,
        onSkipToSettings: () => skipped = true,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller, () => skipped);
}

void main() {
  setUp(() {
    // Clipboard 走 platform channel；测试环境置空处理器避免 MissingPlugin。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });

  testWidgets('未安装：pkg 步骤 + brew 次引导 + 复制按钮 + 重新检测', (tester) async {
    final (controller, _) = await _pumpOnboarding(
      tester,
      FakeContainerBridge()..binaryPath = null,
    );

    expect(find.text('未安装 Apple container 运行时'), findsOneWidget);
    expect(
      find.textContaining('container-1.6.0-installer-signed.pkg'),
      findsOneWidget,
    );
    expect(find.textContaining('brew install container'), findsWidgets);
    expect(find.text('复制官方下载页地址'), findsOneWidget);
    expect(find.text('复制 brew 安装命令'), findsOneWidget);

    await tester.tap(find.text('复制官方下载页地址'));
    await tester.pumpAndSettle();
    expect(find.text('已复制下载页地址'), findsOneWidget);

    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();
    expect(controller.lastError, isNull);
  });

  testWidgets('版本过低：显示检测值与基线 + 升级指引', (tester) async {
    await _pumpOnboarding(
      tester,
      FakeContainerBridge()
        ..versionResult = const BridgeCommandResult(
          exitCode: 0,
          stdout:
              '[{"appName":"container","version":"1.5.0"},'
              '{"appName":"container-apiserver","version":"1.5.0"}]',
          stderr: '',
        ),
    );

    expect(find.text('运行时版本过低'), findsOneWidget);
    expect(find.textContaining('1.5.0'), findsWidgets);
    expect(find.textContaining('1.6.0'), findsWidgets);
    expect(find.text('复制 pkg 升级命令'), findsOneWidget);
    expect(find.text('复制 brew 升级命令'), findsOneWidget);
  });

  testWidgets('跳过出口回调生效', (tester) async {
    final (_, skipped) = await _pumpOnboarding(
      tester,
      FakeContainerBridge()..binaryPath = null,
    );
    await tester.tap(find.text('跳过并仅查看设置'));
    await tester.pumpAndSettle();
    expect(skipped(), isTrue);
  });
}
