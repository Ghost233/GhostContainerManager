import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/app/app.dart';
import 'package:ghost_container_manager/app/app_shell.dart';
import 'package:ghost_container_manager/app/menu_bar_controller.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
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
    expect(find.text('运行时未启动'), findsNothing);
  });

  testWidgets('serviceNotRunning：降级壳横幅 + 一键启动 + 可导航到运行时页', (tester) async {
    final fake = FakeContainerBridge()..statusResult = _stopped();
    await _pumpApp(tester, fake);

    expect(find.text('运行时未启动'), findsOneWidget);
    expect(find.text('启动运行时'), findsWidgets); // 横幅按钮
    expect(find.text('打开引导检查'), findsWidgets);

    await tester.tap(find.text('运行时'));
    await tester.pumpAndSettle();
    expect(find.text('服务未运行'), findsWidgets);
  });

  testWidgets('kernelMissing：横幅提示内核缺失 + 一键安装', (tester) async {
    final fake = FakeContainerBridge()..kernelPresent = false;
    await _pumpApp(tester, fake);

    expect(find.text('运行时缺少默认内核，容器无法启动'), findsOneWidget);
    expect(find.text('安装推荐内核'), findsWidgets);
  });

  testWidgets('notInstalled：阻塞向导 + 跳过出口进入设置', (tester) async {
    final fake = FakeContainerBridge()..binaryPath = null;
    await _pumpApp(tester, fake);

    expect(find.text('未安装 Apple container 运行时'), findsOneWidget);
    expect(find.text('容器'), findsNothing); // 主壳被阻塞

    await tester.tap(find.text('跳过并仅查看设置'));
    await tester.pumpAndSettle();
    expect(find.text('MCP 服务'), findsOneWidget); // 落在设置页
    expect(find.text('容器'), findsWidgets); // 壳已可见
  });

  testWidgets('unsupportedMajor：阻塞向导，不提供「勉强继续」', (tester) async {
    final fake = FakeContainerBridge()
      ..versionResult = const BridgeCommandResult(
        exitCode: 0,
        stdout:
            '[{"appName":"container","version":"2.0.0"},'
            '{"appName":"container-apiserver","version":"2.0.0"}]',
        stderr: '',
      );
    await _pumpApp(tester, fake);

    expect(find.text('运行时大版本不兼容'), findsOneWidget);
    expect(find.text('跳过并仅查看设置'), findsOneWidget);
  });

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
}
