import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/features/system/runtime_page.dart';
import 'package:ghost_container_manager/services/system_service.dart';

Future<(ReadinessController, FakeContainerBridge)> _pumpPage(
  WidgetTester tester,
  FakeContainerBridge fake,
) async {
  final controller = ReadinessController(
    systemService: SystemService(bridge: fake),
    bridge: fake,
  );
  await controller.refresh();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: RuntimePage(controller: controller)),
    ),
  );
  await tester.pumpAndSettle();
  return (controller, fake);
}

void main() {
  testWidgets('就绪态：状态卡显示双端版本/安装路径/内核/资源', (tester) async {
    await _pumpPage(tester, FakeContainerBridge());

    expect(find.text('运行时'), findsOneWidget);
    expect(find.text('服务运行中'), findsOneWidget);
    expect(find.text('CLI 1.6.0 / apiserver 1.6.0'), findsOneWidget);
    expect(find.text('/opt/homebrew/bin/container'), findsOneWidget);
    expect(find.text('默认内核已就位'), findsOneWidget);
    expect(find.textContaining('容器 1 运行中 / 2 共'), findsOneWidget);
    expect(find.text('重新运行引导检查'), findsOneWidget);
  });

  testWidgets('服务未运行：一键启动且 system start 必带内核 flag', (tester) async {
    final (controller, fake) = await _pumpPage(
      tester,
      FakeContainerBridge()
        ..statusResult = const BridgeCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: '',
        ),
    );

    expect(find.text('启动运行时'), findsOneWidget);
    await tester.tap(find.text('启动运行时'));
    await tester.pumpAndSettle();

    // 内核在位 → --disable-kernel-install（installKernel=false）
    expect(fake.calls, contains('systemStart installKernel=false'));
    expect(controller.lastError, isNull);
  });

  testWidgets('内核缺失时启动：system start 带 --enable-kernel-install', (tester) async {
    final (_, fake) = await _pumpPage(
      tester,
      FakeContainerBridge()
        ..kernelPresent = false
        ..statusResult = const BridgeCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: '',
        ),
    );

    await tester.tap(find.text('启动运行时'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('systemStart installKernel=true'));
  });

  testWidgets('kernelMissing：安装推荐内核按钮触发 kernel set', (tester) async {
    final (_, fake) = await _pumpPage(
      tester,
      FakeContainerBridge()..kernelPresent = false,
    );

    expect(find.text('安装推荐内核'), findsWidgets);
    await tester.tap(find.text('安装推荐内核').first);
    await tester.pumpAndSettle();
    expect(fake.calls, contains('kernelSetRecommended force=false'));
  });

  testWidgets('停止运行时：确认弹窗列出运行中容器数，确认后执行 stop', (tester) async {
    final (_, fake) = await _pumpPage(tester, FakeContainerBridge());

    await tester.tap(find.text('停止运行时'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前 1 个容器运行中'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fake.calls, isNot(contains('systemStop')));

    await tester.tap(find.text('停止运行时'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止运行时').last); // 弹窗确认钮
    await tester.pumpAndSettle();
    expect(fake.calls, contains('systemStop'));
  });
}
