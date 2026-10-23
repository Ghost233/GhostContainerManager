import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/compose/compose_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

import '../../services/container_service_test.dart' show snapshotPayload;

Future<ReadinessController> _readyReadiness(FakeContainerBridge fake) async {
  final controller = ReadinessController(
    systemService: SystemService(bridge: fake),
    bridge: fake,
  );
  await controller.refresh();
  return controller;
}

void main() {
  late FakeContainerBridge fake;
  late ComposeService composeService;

  setUp(() {
    fake = FakeContainerBridge();
    composeService = ComposeService(
      bridge: fake,
      containerService: ContainerService(bridge: fake),
    );
  });

  Future<void> pump(WidgetTester tester) async {
    final readiness = await _readyReadiness(fake);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposePage(
            service: composeService,
            controller: readiness,
            onOpenRuntime: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('插件已装：项目列表 + up/down 表单，dry-run 透传计划输出', (tester) async {
    fake.containers = [
      snapshotPayload(
        id: 'shop-web',
        labels: const {
          'com.compose.project': 'shop',
          'com.compose.service': 'web',
        },
      ),
    ];
    fake.composeRunScript = [
      const BridgeCommandResult(
        exitCode: 0,
        stdout: 'plan: would create container shop-web',
        stderr: '',
      ),
    ];
    await pump(tester);

    expect(find.text('未检测到 compose 插件'), findsNothing);
    expect(find.text('shop'), findsOneWidget);
    expect(find.text('up / down'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'compose 文件绝对路径'),
      '/tmp/compose.yaml',
    );
    await tester.tap(find.byType(Checkbox));
    await tester.tap(find.widgetWithText(FilledButton, 'up'));
    await tester.pumpAndSettle();

    expect(
      fake.calls,
      contains(
        'composeRun up --file /tmp/compose.yaml --dry-run --pull missing',
      ),
    );
    expect(find.text('插件输出'), findsOneWidget);
    expect(
      find.textContaining('would create container shop-web'),
      findsOneWidget,
    );
  });

  testWidgets('插件缺失：安装引导 + 重新检测', (tester) async {
    fake.composeHelpResult = const BridgeCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'Error: unknown command "compose"',
    );
    await pump(tester);

    expect(find.text('未检测到 compose 插件'), findsOneWidget);
    expect(
      find.textContaining('/usr/local/libexec/container-plugins/'),
      findsOneWidget,
    );
    expect(find.text('重新检测'), findsOneWidget);

    // 「重新检测」重新探测插件（composeHelp 再被调一次）。
    final before = fake.calls.where((c) => c == 'composeHelp').length;
    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();
    final after = fake.calls.where((c) => c == 'composeHelp').length;
    expect(after, greaterThan(before));
  });

  testWidgets('未就绪：全局未就绪占位，不出现 compose 表单', (tester) async {
    fake.binaryPath = null;
    final readiness = await _readyReadiness(fake);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposePage(
            service: composeService,
            controller: readiness,
            onOpenRuntime: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('打开引导检查'), findsOneWidget);
    expect(find.text('up / down'), findsNothing);
  });
}
