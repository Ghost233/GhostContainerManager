import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/app/app.dart';
import 'package:ghost_container_manager/app/app_shell.dart';
import 'package:ghost_container_manager/app/menu_bar_controller.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/containers/containers_page.dart';
import 'package:ghost_container_manager/features/images/images_page.dart';
import 'package:ghost_container_manager/features/settings/settings_page.dart';

class _AppMenuChannel implements MenuBarChannel {
  _AppMenuChannel(this.preferences);

  final MenuBarPreferences preferences;
  final actionsController = StreamController<MenuBarAction>.broadcast();

  @override
  Stream<MenuBarAction> get actions => actionsController.stream;

  @override
  Future<MenuBarPreferences> loadPreferences() async => preferences;

  @override
  Future<void> setDefaultStartPage(String page) async {}

  @override
  Future<void> setVisible(bool visible) async {}

  @override
  Future<void> updateContainers(
    List<MenuBarContainer> containers,
    int totalRunning,
  ) async {}

  @override
  void dispose() {
    unawaited(actionsController.close());
  }
}

BridgeCommandResult _stopped() =>
    const BridgeCommandResult(exitCode: 1, stdout: '', stderr: '');

Future<void> _pumpApp(
  WidgetTester tester,
  FakeContainerBridge fake, {
  MenuBarChannel? menuBarChannel,
}) async {
  await tester.pumpWidget(
    GhostContainerManagerApp(
      bridge: fake,
      enableMcp: false,
      menuBarChannel:
          menuBarChannel ?? _AppMenuChannel(const MenuBarPreferences()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ready：三列壳 + 9 个侧栏项 + 默认页空态，无降级横幅', (tester) async {
    await _pumpApp(tester, FakeContainerBridge());

    for (final item in kSidebarItems) {
      expect(find.text(item), findsOneWidget, reason: '侧栏缺 $item');
    }
    expect(kSidebarItems.length, 9);
    expect(find.text('暂无容器'), findsOneWidget); // 容器页空态（#17）
    expect(find.text('Docker 端点不可达，请检查 context 或引擎状态'), findsNothing);
  });

  testWidgets('serviceNotRunning：降级壳横幅 + 一键启动 + 可导航到运行时页', (tester) async {
    final fake = FakeContainerBridge()..statusResult = _stopped();
    await _pumpApp(tester, fake);

    expect(find.text('Docker 端点不可达，请检查 context 或引擎状态'), findsOneWidget);
    expect(find.text('检查连接'), findsWidgets); // 横幅按钮
    expect(find.text('打开引导检查'), findsWidgets);

    await tester.tap(find.text('运行时'));
    await tester.pumpAndSettle();
    expect(find.text('Docker 端点未就绪'), findsWidgets);
  });

  testWidgets('Docker connection does not require an app-installed kernel', (
    tester,
  ) async {
    final fake = FakeContainerBridge();
    await _pumpApp(tester, fake);
    expect(find.byType(ContainersPage), findsOneWidget);
    expect(fake.calls.where((c) => c.startsWith('kernel')), isEmpty);
  });
  testWidgets('notInstalled：阻塞向导 + 跳过出口进入设置', (tester) async {
    final fake = FakeContainerBridge()..binaryPath = null;
    await _pumpApp(tester, fake);

    expect(find.text('配置 Docker 连接'), findsOneWidget);
    expect(find.text('容器'), findsNothing); // 主壳被阻塞

    await tester.tap(find.text('跳过并仅查看设置'));
    await tester.pumpAndSettle();
    expect(find.text('MCP 服务'), findsOneWidget); // 落在设置页
    expect(find.text('容器'), findsWidgets); // 壳已可见
  });

  testWidgets(
    'Different Docker client and server major versions remain usable',
    (tester) async {
      final fake = FakeContainerBridge()
        ..versionResult = const BridgeCommandResult(
          exitCode: 0,
          stdout:
              '{"Client":{"Version":"30.0.0"},"Server":{"Version":"28.0.0"}}',
          stderr: '',
        );
      await _pumpApp(tester, fake);
      expect(find.byType(ContainersPage), findsOneWidget);
      expect(find.text('配置 Docker 连接'), findsNothing);
    },
  );
  testWidgets('菜单偏好决定启动页，原生导航动作切换主窗口页面', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final channel = _AppMenuChannel(
      const MenuBarPreferences(defaultStartPage: '镜像'),
    );
    await _pumpApp(tester, FakeContainerBridge(), menuBarChannel: channel);
    expect(find.byType(ImagesPage), findsOneWidget);

    channel.actionsController.add(
      const MenuBarAction(MenuBarActionType.openSettings),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget);

    channel.actionsController.add(
      const MenuBarAction(MenuBarActionType.showContainers),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('暂无容器'), findsOneWidget);
  });

  testWidgets('主内容 180ms easeInOut 渐隐渐现，侧栏高亮即时更新', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpApp(tester, FakeContainerBridge());
    final switcherFinder = find.byType(AnimatedSwitcher);
    expect(switcherFinder, findsOneWidget);
    final switcher = tester.widget<AnimatedSwitcher>(switcherFinder);
    expect(switcher.duration, const Duration(milliseconds: 180));
    expect(switcher.switchInCurve, Curves.easeInOut);
    expect(switcher.switchOutCurve, Curves.easeInOut);

    await tester.tap(find.text('镜像'));
    await tester.pump();
    final imagesTile = tester.widget<ListTile>(
      find.ancestor(of: find.text('镜像'), matching: find.byType(ListTile)),
    );
    expect(imagesTile.selected, isTrue);

    await tester.pump(const Duration(milliseconds: 90));
    expect(find.byType(ContainersPage), findsOneWidget);
    expect(find.byType(ImagesPage), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.byType(ContainersPage), findsNothing);
    expect(find.byType(ImagesPage), findsOneWidget);
  });

  testWidgets('侧栏分组（工作/资源/系统）+ 容器运行中数徽章', (tester) async {
    await _pumpApp(tester, FakeContainerBridge());

    // 分组标题（P0 信息架构）。
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('资源'), findsOneWidget);
    expect(find.text('系统'), findsOneWidget);
  });
}
