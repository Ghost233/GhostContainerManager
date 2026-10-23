import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/networks/networks_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/network_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

import '../../services/container_service_test.dart' show snapshotPayload;

const _networkListJson =
    '[{"configuration":{"name":"default","mode":"nat","plugin":"builtin",'
    '"labels":{"com.apple.container.resource.role":"builtin"}},'
    '"status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}},'
    '{"configuration":{"name":"backend","mode":"nat","plugin":"builtin",'
    '"labels":{}},"status":{"ipv4Subnet":"192.168.65.0/24"}}]';

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
    fake = FakeContainerBridge()
      ..networkListResult = const BridgeCommandResult(
        exitCode: 0,
        stdout: _networkListJson,
        stderr: '',
      )
      ..containers = [snapshotPayload(id: 'web')];
  });

  Future<void> pump(WidgetTester tester) async {
    final readiness = await _readyReadiness(fake);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NetworksPage(
            service: NetworkService(
              bridge: fake,
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

  testWidgets('ready：网络表含子网/模式/容器数，内建标记，无写入口', (tester) async {
    await pump(tester);

    expect(find.text('网络'), findsOneWidget);
    expect(find.text('default'), findsOneWidget);
    expect(find.text('backend'), findsOneWidget);
    expect(find.text('内建'), findsOneWidget);
    expect(find.textContaining('192.168.64.0/24'), findsOneWidget);
    expect(find.textContaining('1 个容器'), findsOneWidget);
    // 只读红线。
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.delete), findsNothing);
  });

  testWidgets('行展开按需加载成员容器', (tester) async {
    await pump(tester);

    await tester.tap(find.text('default'));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget);
    expect(fake.calls, contains('networkList'));
  });

  testWidgets('未就绪：全局未就绪占位', (tester) async {
    fake.binaryPath = null;
    final readiness = await _readyReadiness(fake);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NetworksPage(
            service: NetworkService(
              bridge: fake,
              containerService: ContainerService(bridge: fake),
            ),
            controller: readiness,
            onOpenRuntime: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('打开引导检查'), findsOneWidget);
    expect(find.text('default'), findsNothing);
  });
}
