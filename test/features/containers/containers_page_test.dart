import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/containers/containers_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// 与 test/services/container_service_test.dart 相同的 1.6.0 快照形态。
Map<String, Object?> snapshotPayload({
  required String id,
  String image = 'docker.io/library/nginx:latest',
  String status = 'running',
  Map<String, String> labels = const {},
  String? ip = '192.168.64.3/24',
  String? startedAt = '2026-10-20T08:00:05Z',
}) {
  return <String, Object?>{
    'configuration': <String, Object?>{
      'id': id,
      'image': <String, Object?>{'reference': image},
      'labels': labels,
      'creationDate': '2026-10-20T08:00:00Z',
      'stopSignal': 'SIGTERM',
      'initProcess': <String, Object?>{
        'executable': '/sbin/init',
        'arguments': <String>['--serve'],
        'environment': <String>['A=1', 'B=2'],
      },
      'publishedPorts': <Object?>[
        <String, Object?>{
          'hostAddress': '0.0.0.0',
          'hostPort': 8080,
          'containerPort': 80,
          'proto': 'tcp',
        },
      ],
    },
    'status': status,
    'networks': ip == null
        ? <Object?>[]
        : <Object?>[
            <String, Object?>{
              'network': 'default',
              'hostname': id,
              'ipv4Address': ip,
              'ipv4Gateway': '192.168.64.1/24',
            },
          ],
    'startedDate': startedAt,
  };
}

Future<(FakeContainerBridge, ContainerService)> _pumpPage(
  WidgetTester tester,
  FakeContainerBridge fake,
) async {
  final readiness = ReadinessController(
    systemService: SystemService(bridge: fake),
    bridge: fake,
  );
  await readiness.refresh();
  final service = ContainerService(bridge: fake);
  addTearDown(service.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ContainersPage(
          service: service,
          controller: readiness,
          onOpenRuntime: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (fake, service);
}

FakeContainerBridge _twoContainers() {
  return FakeContainerBridge()
    ..containers = [
      snapshotPayload(
        id: 'web-frontend',
        labels: const {'com.ghost233.project': 'web'},
      ),
      snapshotPayload(
        id: 'cache',
        image: 'docker.io/library/redis:7',
        status: 'stopped',
        startedAt: null,
      ),
    ];
}

void main() {
  testWidgets('列表：名称/镜像/状态/端口齐全，com.ghost233.* 带「本应用创建」标记', (tester) async {
    await _pumpPage(tester, _twoContainers());

    expect(find.text('web-frontend'), findsOneWidget);
    expect(find.text('cache'), findsOneWidget);
    expect(find.text('docker.io/library/nginx:latest'), findsOneWidget);
    expect(find.text('docker.io/library/redis:7'), findsOneWidget);
    expect(find.text('8080→80'), findsWidgets); // 两个容器同一映射
    expect(find.text('本应用创建'), findsOneWidget); // 仅 web-frontend
    expect(find.text('1 运行中 / 共 2'), findsOneWidget);
  });

  testWidgets('搜索过滤列表', (tester) async {
    await _pumpPage(tester, _twoContainers());

    await tester.enterText(find.byType(TextField), 'redis');
    await tester.pumpAndSettle();

    expect(find.text('cache'), findsOneWidget);
    expect(find.text('web-frontend'), findsNothing);
  });

  testWidgets('点选容器 → 检查器概览：配置键值 + stats 字段可见', (tester) async {
    await _pumpPage(tester, _twoContainers());

    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();

    expect(find.text('返回容器列表'), findsOneWidget);
    expect(find.text('概览'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
    // inspect 配置
    expect(find.text('192.168.64.3（网关 192.168.64.1）'), findsOneWidget);
    expect(find.textContaining('/sbin/init --serve'), findsOneWidget);
    // stats（fake 默认 64MB/512MB、3 进程）
    expect(find.text('内存 64 MB / 512 MB'), findsOneWidget);
    expect(find.text('进程 3'), findsOneWidget);
  });

  testWidgets('已停止容器概览：stats 冲突显示「无实时统计」', (tester) async {
    final (fake, _) = await _pumpPage(tester, _twoContainers());
    fake.statsFailures['cache'] = 'container "cache" not running';

    await tester.tap(find.text('cache'));
    await tester.pumpAndSettle();

    expect(find.text('容器未在运行，无实时统计'), findsOneWidget);
  });

  testWidgets('日志标签页：stdio/boot 双源实时滚动，eof 收尾', (tester) async {
    final fake = _twoContainers()
      ..logResponses['web-frontend'] = [
        BridgeLogEvent.data(
          source: 'stdio',
          bytes: utf8.encode('listening on :80\nready\n'),
        ),
        BridgeLogEvent.data(source: 'boot', bytes: utf8.encode('vm started\n')),
        const BridgeLogEvent.eof(),
      ];
    await _pumpPage(tester, fake);

    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();

    expect(find.text('listening on :80'), findsOneWidget);
    expect(find.text('ready'), findsOneWidget);
    expect(find.text('[boot] vm started'), findsOneWidget);
    expect(find.text('— 日志流已结束 —'), findsOneWidget);
  });

  testWidgets('日志流错误以错误色行呈现', (tester) async {
    final fake = _twoContainers()
      ..logResponses['web-frontend'] = [
        const BridgeLogEvent.error('xpc log handle lost'),
      ];
    await _pumpPage(tester, fake);

    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();

    expect(find.text('日志流错误：xpc log handle lost'), findsOneWidget);
  });

  testWidgets('空态：无容器时显示空态文案', (tester) async {
    await _pumpPage(tester, FakeContainerBridge());

    expect(find.text('暂无容器'), findsOneWidget);
  });

  testWidgets('运行时未启动：统一占位（D8 全局态）', (tester) async {
    final fake = FakeContainerBridge()
      ..statusResult = const BridgeCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: '',
      );
    await _pumpPage(tester, fake);

    expect(find.text('运行时未就绪，容器暂不可用'), findsOneWidget);
    expect(find.text('打开引导检查'), findsOneWidget);
  });

  testWidgets('列表加载失败：错误态 + 重试恢复', (tester) async {
    final fake = _twoContainers()..containerListThrows = true;
    await _pumpPage(tester, fake);

    expect(find.text('容器列表加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    fake.containerListThrows = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('web-frontend'), findsOneWidget);
  });

  testWidgets('外部删除选中容器后自动退回列表', (tester) async {
    final (fake, service) = await _pumpPage(tester, _twoContainers());

    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();
    expect(find.text('返回容器列表'), findsOneWidget);

    // 模拟外部删除 + 一次轮询刷新（快照流更新驱动 UI）
    fake.containers = [
      snapshotPayload(
        id: 'cache',
        image: 'docker.io/library/redis:7',
        status: 'stopped',
        startedAt: null,
      ),
    ];
    await service.refresh();
    await tester.pumpAndSettle();

    expect(find.text('返回容器列表'), findsNothing);
    expect(find.text('web-frontend'), findsNothing);
    expect(find.text('cache'), findsOneWidget);
  });
}
