import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/app/menu_bar_controller.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/settings/mcp_settings_controller.dart';
import 'package:ghost_container_manager/features/settings/settings_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/mcp/tool_audit.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:ghost_container_manager/ui/colors.dart';
import 'package:ghost_container_manager/ui/components.dart';

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

  testWidgets('设置页选择并清除运行时数据目录，显示当前路径', (tester) async {
    final bridge = FakeContainerBridge();
    final service = SystemService(bridge: bridge);
    final readiness = ReadinessController(
      systemService: service,
      bridge: bridge,
    );
    addTearDown(readiness.dispose);
    await readiness.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            mcp: _controller(),
            menuBar: _menuBar(),
            readiness: readiness,
            selectDirectory: () async => '/Volumes/data/container',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('选择目录'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('使用默认设置'), findsOneWidget);
    expect(find.text('/app/root/'), findsOneWidget);
    await tester.tap(find.text('选择目录'));
    await tester.pumpAndSettle();
    expect(find.text('/Volumes/data/container'), findsOneWidget);
    expect(bridge.appRoot, '/Volumes/data/container');
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(find.text('使用默认设置'), findsOneWidget);
    expect(bridge.appRoot, isNull);
  });

  testWidgets('设置损坏时提示读取失败并可恢复默认', (tester) async {
    final bridge = FakeContainerBridge()..appRootReadError = '无法读取运行时数据目录设置';
    final readiness = ReadinessController(
      systemService: SystemService(bridge: bridge),
      bridge: bridge,
    );
    addTearDown(readiness.dispose);
    await readiness.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            mcp: _controller(),
            menuBar: _menuBar(),
            readiness: readiness,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('恢复默认'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('无法读取设置'), findsOneWidget);
    expect(find.text('无法读取运行时数据目录设置'), findsOneWidget);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(find.text('使用默认设置'), findsOneWidget);
  });

  testWidgets('离开设置页后目录选择结果不会更新设置', (tester) async {
    final bridge = FakeContainerBridge();
    final readiness = ReadinessController(
      systemService: SystemService(bridge: bridge),
      bridge: bridge,
    );
    addTearDown(readiness.dispose);
    await readiness.refresh();
    final choice = Completer<String?>();
    var pickerOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            mcp: _controller(),
            menuBar: _menuBar(),
            readiness: readiness,
            selectDirectory: () {
              pickerOpened = true;
              return choice.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('选择目录'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择目录'));
    expect(pickerOpened, isTrue);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    choice.complete('/Volumes/data/container');
    await tester.pumpAndSettle();
    expect(bridge.appRoot, isNull);
    expect(tester.takeException(), isNull);
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
    expect(find.byType(SectionCard, skipOffstage: false), findsNWidgets(4));
    for (final title in ['通用', 'MCP 服务', '最近调用', '关于']) {
      expect(
        find.widgetWithText(SectionCard, title, skipOffstage: false),
        findsOneWidget,
      );
    }
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
    expect(find.byKey(Key('copy-value-${mcp.endpoint}')), findsOneWidget);

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
    final titleStyle = tester.widget<Text>(find.text('设置')).style;
    expect(
      titleStyle?.fontSize,
      Theme.of(tester.element(find.text('设置'))).textTheme.titleLarge?.fontSize,
    );
    for (final label in ['外观', '行为']) {
      final labelContext = tester.element(find.text(label));
      final labelStyle = tester.widget<Text>(find.text(label)).style;
      expect(
        labelStyle?.fontSize,
        Theme.of(labelContext).textTheme.bodySmall?.fontSize,
      );
      expect(labelStyle?.color, GcmColors.textSecondary(labelContext));
    }
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

  testWidgets('最近调用简表：有记录时显示工具名/时间/耗时', (tester) async {
    final auditor = McpToolAuditor();
    auditor.record(
      tool: 'container_list',
      startedAt: DateTime(2026, 10, 24, 9, 8, 7),
      succeeded: true,
      duration: const Duration(milliseconds: 42),
    );
    auditor.record(
      tool: 'container_delete',
      startedAt: DateTime(2026, 10, 24, 9, 9, 10),
      succeeded: false,
      duration: const Duration(milliseconds: 5),
    );
    final bridge = FakeContainerBridge();
    final mcp = McpSettingsController(
      systemService: SystemService(bridge: bridge),
      containerService: ContainerService(bridge: bridge),
      auditor: auditor,
    )..enabled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(mcp: mcp, menuBar: _menuBar()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无 MCP 调用记录'), findsNothing);
    expect(find.text('container_delete'), findsOneWidget);
    expect(find.text('container_list'), findsOneWidget);
    expect(find.text('09:09:10'), findsOneWidget);
    expect(find.text('42ms'), findsOneWidget);
    expect(find.text('5ms'), findsOneWidget);
    final successIcon = find.byIcon(Icons.check_circle_outline);
    expect(tester.widget<Icon>(successIcon).color, GcmColors.success);
  });
}
