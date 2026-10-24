import 'dart:async';
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
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
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

  testWidgets('空态主操作打开创建表单并创建容器', (tester) async {
    final (fake, _) = await _pumpPage(tester, FakeContainerBridge());

    expect(find.text('暂无容器'), findsOneWidget);
    await tester.tap(find.byKey(const Key('empty-create-container-button')));
    await tester.pumpAndSettle();
    expect(find.text('新建容器'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();
    expect(find.text('请输入本地镜像引用'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('create-name-field')),
      'new-api',
    );
    await tester.enterText(
      find.byKey(const Key('create-image-field')),
      'nginx:latest',
    );
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    expect(fake.createRequests.single['id'], 'new-api');
    expect(fake.createRequests.single['image'], 'nginx:latest');
    expect(find.text('new-api'), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
  });

  testWidgets('启动和重启均有确认弹窗并经过 Service', (tester) async {
    final (fake, _) = await _pumpPage(tester, _twoContainers());

    await tester.tap(find.byKey(const Key('container-actions-cache')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动'));
    await tester.pumpAndSettle();
    expect(find.text('启动容器'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '启动'));
    await tester.pumpAndSettle();
    expect(fake.startCalls, 1);

    await tester.tap(find.byKey(const Key('container-actions-web-frontend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重启'));
    await tester.pumpAndSettle();
    expect(find.text('重启容器'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '重启'));
    await tester.pumpAndSettle();
    expect(fake.stopCalls, 1);
    expect(fake.startCalls, 2);
  });

  testWidgets('停止确认后立即呈现合成态，完成后回到原生停止态', (tester) async {
    final fake = _twoContainers()..stopGate = Completer<void>();
    await _pumpPage(tester, fake);

    await tester.tap(find.byKey(const Key('container-actions-web-frontend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(find.text('停止容器'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '停止'));
    await tester.pumpAndSettle();

    expect(find.text('停止中'), findsOneWidget);
    final menu = tester.widget<PopupMenuButton<String>>(
      find.byKey(const Key('container-actions-web-frontend')),
    );
    expect(menu.enabled, isFalse);

    fake.stopGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('停止中'), findsNothing);
    expect(find.text('已停止'), findsWidgets);
  });

  testWidgets('停止等待超时只提示，后台操作仍继续', (tester) async {
    final fake = _twoContainers()..stopGate = Completer<void>();
    await _pumpPage(tester, fake);

    await tester.tap(find.byKey(const Key('container-actions-web-frontend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '停止'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));

    expect(find.textContaining('后台停止操作仍会继续'), findsOneWidget);
    expect(find.text('停止中'), findsOneWidget);
    expect(fake.stopCalls, 1);

    fake.stopGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('停止中'), findsNothing);
    expect(find.text('已停止'), findsWidgets);
  });

  testWidgets('删除运行中容器：force 默认不勾，勾选确认后才执行', (tester) async {
    final (fake, _) = await _pumpPage(tester, _twoContainers());

    await tester.tap(find.byKey(const Key('container-actions-web-frontend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除容器'), findsOneWidget);
    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isFalse);
    final disabledDelete = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '删除'),
    );
    expect(disabledDelete.onPressed, isNull);
    expect(fake.deleteCalls, 0);

    await tester.tap(find.text('强制停止并删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(fake.deleteCalls, 1);
    expect(find.text('web-frontend'), findsNothing);
  });

  testWidgets('终端：一次性命令展示 stdout、stderr、退出码与截断标记', (tester) async {
    final fake = _twoContainers()
      ..execResult = const BridgeExecResult(
        exitCode: 23,
        stdout: 'hello from stdout',
        stderr: 'warning from stderr',
        stdoutTruncated: true,
        stderrTruncated: true,
      );
    await _pumpPage(tester, fake);
    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('container-terminal-command')),
      'printf "hello world"',
    );
    await tester.tap(find.byKey(const Key('container-terminal-run')));
    await tester.pumpAndSettle();

    expect(fake.execRequests.single, <String, Object?>{
      'id': 'web-frontend',
      'command': <String>['printf', 'hello world'],
      'env': <String>[],
      'workdir': null,
      'user': null,
      'timeoutSeconds': 60,
    });
    expect(find.text('退出码 23'), findsOneWidget);
    expect(find.text('hello from stdout'), findsOneWidget);
    expect(find.text('warning from stderr'), findsOneWidget);
    expect(find.textContaining('stdout 已截断至 64 KiB'), findsOneWidget);
    expect(find.textContaining('stderr 已截断至 64 KiB'), findsOneWidget);
  });

  testWidgets('终端：Service 错误在执行区展示且允许重试', (tester) async {
    final fake = _twoContainers()
      ..writeFailures['exec:web-frontend'] = 'exec permission denied';
    await _pumpPage(tester, fake);
    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('container-terminal-command')),
      'id -u',
    );
    await tester.tap(find.byKey(const Key('container-terminal-run')));
    await tester.pumpAndSettle();

    expect(find.textContaining('执行失败：'), findsOneWidget);
    expect(
      find.textContaining('Permission denied during exec'),
      findsOneWidget,
    );
    expect(find.textContaining('PERMISSION_DENIED'), findsOneWidget);
    final run = tester.widget<FilledButton>(
      find.byKey(const Key('container-terminal-run')),
    );
    expect(run.onPressed, isNotNull);
  });

  testWidgets('日志视图只保留尾部 5000 行', (tester) async {
    final fake = _twoContainers()
      ..logResponses['web-frontend'] = [
        BridgeLogEvent.data(
          source: 'stdio',
          bytes: utf8.encode(
            List.generate(5005, (index) => 'line-$index').join('\n'),
          ),
        ),
      ];
    await _pumpPage(tester, fake);
    await tester.tap(find.text('web-frontend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    final delegate = list.childrenDelegate as SliverChildListDelegate;
    expect(delegate.estimatedChildCount, 5000);
    expect(delegate.children, hasLength(5000));
    expect((delegate.children.first as Text).data, 'line-5');
    expect((delegate.children.last as Text).data, 'line-5004');
  });
}
