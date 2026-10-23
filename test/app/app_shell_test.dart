import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/app/app.dart';
import 'package:ghost_container_manager/app/app_shell.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';

BridgeCommandResult _stopped() =>
    const BridgeCommandResult(exitCode: 1, stdout: '', stderr: '');

Future<void> _pumpApp(WidgetTester tester, FakeContainerBridge fake) async {
  await tester.pumpWidget(
    GhostContainerManagerApp(bridge: fake, enableMcp: false),
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
    expect(find.text('容器'), findsOneWidget); // 壳已可见
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
}
