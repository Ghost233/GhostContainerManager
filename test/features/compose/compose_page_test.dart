import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/compose/compose_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:ghost_container_manager/ui/components.dart';

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

  test('refresh wraps non-GcmException failures', () async {
    fake.containers = [
      <String, Object?>{
        'configuration': <String, Object?>{'id': 7},
      },
    ];
    final controller = ComposeController(service: composeService);
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(controller.loading, isFalse);
    expect(
      controller.lastError,
      isA<GcmException>()
          .having((e) => e.code, 'code', GcmErrorCode.internal)
          .having((e) => e.message, 'message', '未预期的错误')
          .having((e) => e.cause, 'cause', isNotNull),
    );
  });

  test('run wraps non-GcmException failures', () async {
    fake.containers = [
      <String, Object?>{
        'configuration': <String, Object?>{'id': 7},
      },
    ];
    final controller = ComposeController(service: composeService);
    addTearDown(controller.dispose);

    await controller.up(file: '/tmp/compose.yaml');

    expect(controller.running, isFalse);
    expect(
      controller.lastError,
      isA<GcmException>()
          .having((e) => e.code, 'code', GcmErrorCode.internal)
          .having((e) => e.message, 'message', '未预期的错误')
          .having((e) => e.cause, 'cause', isNotNull),
    );
  });

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

  testWidgets('项目详情卡片化，服务状态点与容器标识可复制', (tester) async {
    fake.containers = [
      snapshotPayload(
        id: 'shop-web',
        labels: const {
          'com.compose.project': 'shop',
          'com.compose.service': 'web',
        },
      ),
      snapshotPayload(
        id: 'shop-db',
        status: 'stopped',
        labels: const {
          'com.compose.project': 'shop',
          'com.compose.service': 'db',
        },
      ),
    ];
    await pump(tester);

    expect(find.byType(SectionCard), findsOneWidget);
    expect(find.text('1/2 个服务运行中'), findsOneWidget);
    final servicesToggle = find.byKey(
      const Key('compose-services-toggle-shop'),
    );
    expect(servicesToggle, findsOneWidget);
    expect(find.byType(StateDot), findsNothing);

    await tester.tap(servicesToggle);
    await tester.pump();

    expect(find.byType(StateDot), findsNWidgets(2));
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.widgetWithText(CopyValue, 'shop-web'), findsOneWidget);
    expect(find.widgetWithText(CopyValue, 'shop-db'), findsOneWidget);
    final states = tester
        .widgetList<StateDot>(find.byType(StateDot))
        .map((dot) => dot.state)
        .toList();
    expect(states, ['running', 'stopped']);
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
