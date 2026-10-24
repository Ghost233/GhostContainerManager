import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/app/menu_bar_controller.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/settings/mcp_settings_controller.dart';
import 'package:ghost_container_manager/features/settings/settings_page.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

McpSettingsController _controller() {
  final bridge = FakeContainerBridge();
  return McpSettingsController(
    systemService: SystemService(bridge: bridge),
    containerService: ContainerService(bridge: bridge),
  );
}

MenuBarController _menuBar({MenuBarChannel? channel}) => MenuBarController(
  containers: ContainerService(bridge: FakeContainerBridge()),
  channel: channel ?? MethodChannelMenuBarChannel(),
);

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });

  testWidgets('MCP 区块：开关/端口默认 35731/空最近调用简表', (tester) async {
    final mcp = _controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(mcp: mcp, menuBar: _menuBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP 服务'), findsOneWidget);
    expect(find.text('启用内置 MCP server'), findsOneWidget);
    final switchWidget = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '启用内置 MCP server'),
    );
    expect(switchWidget.value, isTrue); // MCP-first 默认开

    final portField = tester.widget<TextField>(find.byType(TextField));
    expect(portField.controller!.text, '35731');

    expect(find.text('最近调用'), findsOneWidget);
    expect(find.text('暂无 MCP 调用记录'), findsOneWidget);
  });

  testWidgets('开关联动真实 server：开启后显示运行中端点，关闭后停用', (tester) async {
    final mcp = _controller()
      ..enabled =
          false // 初始关，避免依赖固定端口
      ..port = 0; // 让系统分配空闲端口
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(mcp: mcp, menuBar: _menuBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停用'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, '启用内置 MCP server'));
    // 真实 socket 绑定需要真实事件循环（testWidgets 默认 fake async）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(mcp.running, isTrue, reason: mcp.lastError ?? 'no error recorded');
    expect(find.textContaining('运行中：http://127.0.0.1:'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, '启用内置 MCP server'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(mcp.running, isFalse);
  });

  testWidgets('通用区块：菜单栏与默认启动页可用，中文语言按规格禁用', (tester) async {
    final methodChannel = const MethodChannel('gcm/menu_bar_settings_test');
    final nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          nativeCalls.add(call);
          if (call.method == 'getPreferences') {
            return <String, Object?>{'visible': true, 'defaultStartPage': '容器'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null),
    );
    final menuBar = _menuBar(
      channel: MethodChannelMenuBarChannel(channel: methodChannel),
    );
    addTearDown(menuBar.dispose);
    await menuBar.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(mcp: _controller(), menuBar: menuBar),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('通用'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('行为'), findsOneWidget);
    expect(find.text('显示菜单栏图标'), findsOneWidget);
    expect(find.text('默认启动页'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('中文'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-menu-bar-visible')));
    await tester.pump();
    expect(menuBar.visible, isFalse);
    expect(
      nativeCalls.any(
        (call) =>
            call.method == 'setVisible' &&
            (call.arguments as Map<Object?, Object?>)['visible'] == false,
      ),
      isTrue,
    );

    await tester.tap(find.byKey(const Key('settings-default-start-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('镜像').last);
    await tester.pump();
    expect(menuBar.defaultStartPage, '镜像');
    expect(
      nativeCalls.any(
        (call) =>
            call.method == 'setDefaultStartPage' &&
            (call.arguments as Map<Object?, Object?>)['page'] == '镜像',
      ),
      isTrue,
    );

    final language = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('settings-language')),
    );
    expect(language.onChanged, isNull);
  });
}
