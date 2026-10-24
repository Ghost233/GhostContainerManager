import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/networks/networks_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/errors.dart';
import 'package:ghost_container_manager/services/network_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:ghost_container_manager/ui/components.dart';

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

  test('refresh wraps non-GcmException failures', () async {
    fake.containers = [
      <String, Object?>{
        'configuration': <String, Object?>{'id': 7},
      },
    ];
    final controller = NetworksController(
      service: NetworkService(
        bridge: fake,
        containerService: ContainerService(bridge: fake),
      ),
    );
    addTearDown(controller.dispose);

    await controller.refresh();

    expect(controller.loading, isFalse);
    expect(controller.networks, isEmpty);
    expect(
      controller.lastError,
      isA<GcmException>()
          .having((e) => e.code, 'code', GcmErrorCode.internal)
          .having((e) => e.message, 'message', '未预期的错误')
          .having((e) => e.cause, 'cause', isNotNull),
    );
  });

  testWidgets('ready：网络表含子网/模式/容器数，内建标记，无写入口', (tester) async {
    await pump(tester);

    expect(find.byType(SectionCard), findsNWidgets(2));
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

    await tester.tap(find.byKey(const Key('network-members-toggle')).first);
    await tester.pumpAndSettle();

    // containerId 可复制；hostname 在 fixture 中也叫 web，不能误算重复 CopyValue。
    expect(find.widgetWithText(CopyValue, 'web'), findsOneWidget);
    expect(find.byType(CopyValue), findsNWidgets(2));
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
