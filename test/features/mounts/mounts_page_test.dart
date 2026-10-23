import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/mounts/mounts_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/mount_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

import '../../services/mount_service_test.dart'
    show payloadWithMounts, virtiofsMount;

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

  setUp(() {
    fake = FakeContainerBridge();
  });

  Future<void> pump(WidgetTester tester) async {
    final readiness = await _readyReadiness(fake);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MountsPage(
            service: MountService(
              containerService: ContainerService(bridge: fake),
            ),
            controller: readiness,
            onOpenRuntime: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ready：聚合表列出来源与使用方，无任何写入口', (tester) async {
    fake.containers = [
      payloadWithMounts('web', [
        virtiofsMount('/Users/x/site', '/usr/share', readOnly: true),
      ]),
    ];
    await pump(tester);

    expect(find.text('挂载'), findsOneWidget);
    expect(find.text('/Users/x/site'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.textContaining('web : /usr/share'), findsOneWidget);
    // 只读红线：没有任何新增/删除/编辑按钮。
    expect(find.text('新建'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.byIcon(Icons.edit), findsNothing);
  });

  testWidgets('ready 且无挂载：空态文案', (tester) async {
    await pump(tester);

    expect(find.text('当前没有容器配置任何挂载'), findsOneWidget);
  });

  testWidgets('未就绪：全局未就绪占位，不出现表格', (tester) async {
    fake.binaryPath = null;
    final readiness = await _readyReadiness(fake);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MountsPage(
            service: MountService(
              containerService: ContainerService(bridge: fake),
            ),
            controller: readiness,
            onOpenRuntime: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('挂载'), findsNothing);
    expect(find.text('打开引导检查'), findsOneWidget);
  });
}
