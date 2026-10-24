import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/app/menu_bar_controller.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/services/container_service.dart';

Map<String, Object?> _running(String id) => <String, Object?>{
  'configuration': <String, Object?>{
    'id': id,
    'image': <String, Object?>{'reference': 'docker.io/library/nginx:latest'},
    'initProcess': <String, Object?>{},
  },
  'status': 'running',
};

class _FakeMenuBarChannel implements MenuBarChannel {
  final StreamController<MenuBarAction> actionController =
      StreamController<MenuBarAction>.broadcast();
  final List<Map<String, Object?>> updates = <Map<String, Object?>>[];
  final List<bool> visibilityWrites = <bool>[];
  final List<String> startPageWrites = <String>[];
  MenuBarPreferences preferences = const MenuBarPreferences();
  Object? visibilityError;
  Object? startPageError;
  var loadPreferencesCalls = 0;

  @override
  Stream<MenuBarAction> get actions => actionController.stream;

  @override
  Future<MenuBarPreferences> loadPreferences() async {
    loadPreferencesCalls++;
    return preferences;
  }

  @override
  Future<void> setDefaultStartPage(String page) async {
    startPageWrites.add(page);
    final error = startPageError;
    if (error != null) throw error;
  }

  @override
  Future<void> setVisible(bool visible) async {
    visibilityWrites.add(visible);
    final error = visibilityError;
    if (error != null) throw error;
  }

  @override
  Future<void> updateContainers(
    List<MenuBarContainer> containers,
    int totalRunning,
  ) async {
    updates.add(<String, Object?>{
      'containers': containers.map((item) => item.toMap()).toList(),
      'totalRunning': totalRunning,
    });
  }

  @override
  void dispose() {
    unawaited(actionController.close());
  }
}

void main() {
  test('初始化幂等：偏好与容器快照只加载一次', () async {
    final bridge = FakeContainerBridge();
    final service = ContainerService(bridge: bridge);
    final channel = _FakeMenuBarChannel()
      ..preferences = const MenuBarPreferences(
        visible: false,
        defaultStartPage: '设置',
      );
    final controller = MenuBarController(containers: service, channel: channel);
    addTearDown(service.dispose);
    addTearDown(controller.dispose);

    await Future.wait([controller.initialize(), controller.initialize()]);
    await controller.initialize();

    expect(channel.loadPreferencesCalls, 1);
    expect(bridge.calls.where((call) => call == 'containerList'), hasLength(1));
    expect(controller.visible, isFalse);
    expect(controller.defaultStartPage, '设置');
  });

  test('偏好原生写失败：乐观更新后回滚并保留错误', () async {
    final bridge = FakeContainerBridge();
    final service = ContainerService(bridge: bridge);
    final channel = _FakeMenuBarChannel()
      ..visibilityError = StateError('visibility failed')
      ..startPageError = StateError('start page failed');
    final controller = MenuBarController(containers: service, channel: channel);
    addTearDown(service.dispose);
    addTearDown(controller.dispose);
    await controller.initialize();

    final visibility = controller.setVisible(false);
    expect(controller.visible, isFalse);
    await visibility;
    expect(controller.visible, isTrue);
    expect(controller.lastError, contains('visibility failed'));

    final startPage = controller.setDefaultStartPage('设置');
    expect(controller.defaultStartPage, '设置');
    await startPage;
    expect(controller.defaultStartPage, '容器');
    expect(controller.lastError, contains('start page failed'));
    expect(channel.visibilityWrites, [false]);
    expect(channel.startPageWrites, ['设置']);
  });

  test('菜单状态：空态、最多 5 项与快捷停止均经过 Service', () async {
    final bridge = FakeContainerBridge();
    final service = ContainerService(bridge: bridge);
    final channel = _FakeMenuBarChannel();
    final controller = MenuBarController(containers: service, channel: channel);
    addTearDown(service.dispose);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.totalRunning, 0);
    expect(controller.runningContainers, isEmpty);
    expect(channel.updates.last['totalRunning'], 0);

    bridge.containers = <Map<String, Object?>>[
      for (var index = 0; index < 6; index++) _running('web-$index'),
      <String, Object?>{
        'configuration': <String, Object?>{'id': 'stopped'},
        'status': 'stopped',
      },
    ];
    await service.refresh();
    await Future<void>.delayed(Duration.zero);

    expect(controller.totalRunning, 6);
    expect(controller.runningContainers.map((item) => item.id), <String>[
      'web-0',
      'web-1',
      'web-2',
      'web-3',
      'web-4',
    ]);
    expect(channel.updates.last['totalRunning'], 6);
    final payload = channel.updates.last['containers']! as List<Object?>;
    expect(payload, hasLength(5));

    await controller.stopContainer('web-0');
    await Future<void>.delayed(Duration.zero);
    expect(bridge.stopCalls, 1);
    expect(controller.totalRunning, 5);
    expect(
      controller.runningContainers.map((item) => item.id),
      contains('web-5'),
    );
  });
}
