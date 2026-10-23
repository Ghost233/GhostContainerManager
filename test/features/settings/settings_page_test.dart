import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
        home: Scaffold(body: SettingsPage(mcp: mcp)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MCP 服务'), findsOneWidget);
    expect(find.text('启用内置 MCP server'), findsOneWidget);
    final switchWidget = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile),
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
        home: Scaffold(body: SettingsPage(mcp: mcp)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停用'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    // 真实 socket 绑定需要真实事件循环（testWidgets 默认 fake async）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(mcp.running, isTrue, reason: mcp.lastError ?? 'no error recorded');
    expect(find.textContaining('运行中：http://127.0.0.1:'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(mcp.running, isFalse);
  });
}
