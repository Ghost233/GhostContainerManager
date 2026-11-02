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
  testWidgets('Docker status, path and resource counts', (tester) async {
    await _pumpPage(tester, FakeContainerBridge());
    expect(find.text('Docker 端点已连接'), findsOneWidget);
    expect(find.text('CLI 29.8.2 / Engine 28.1.0'), findsOneWidget);
    expect(find.text('/opt/homebrew/bin/docker'), findsOneWidget);
    expect(find.textContaining('容器 1 运行中 / 2 共'), findsOneWidget);
  });
  testWidgets('Disconnected endpoint rechecks without engine startup', (
    tester,
  ) async {
    final (controller, fake) = await _pumpPage(
      tester,
      FakeContainerBridge()
        ..statusResult = const BridgeCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Cannot connect',
        ),
    );
    expect(find.text('Docker 端点未就绪'), findsOneWidget);
    await tester.tap(find.text('重新检查连接'));
    await tester.pumpAndSettle();
    expect(controller.readiness!.ready, isFalse);
    expect(fake.calls.where((c) => c.startsWith('systemStart')), isEmpty);
  });
  testWidgets('No kernel probe or installation', (tester) async {
    final (_, fake) = await _pumpPage(tester, FakeContainerBridge());
    expect(find.text('Docker 端点已连接'), findsOneWidget);
    expect(fake.calls.where((c) => c.startsWith('kernel')), isEmpty);
  });
  testWidgets('External engine recovery is visible after refresh', (
    tester,
  ) async {
    final fake = FakeContainerBridge();
    final available = fake.statusResult;
    fake.statusResult = const BridgeCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'offline',
    );
    final (controller, _) = await _pumpPage(tester, fake);
    fake.statusResult = available;
    await tester.tap(find.text('重新检查连接'));
    await tester.pumpAndSettle();
    expect(controller.readiness!.ready, isTrue);
  });
  testWidgets('Engine lifecycle remains external', (tester) async {
    final (_, fake) = await _pumpPage(tester, FakeContainerBridge());
    expect(find.textContaining('引擎启停'), findsOneWidget);
    expect(find.text('停止运行时'), findsNothing);
    expect(fake.calls, isNot(contains('systemStop')));
  });
}
