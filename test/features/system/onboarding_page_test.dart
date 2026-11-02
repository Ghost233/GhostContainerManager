import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/system/onboarding_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/system_service.dart';

Future<(ReadinessController, bool Function())> _pumpOnboarding(
  WidgetTester tester,
  FakeContainerBridge fake,
) async {
  final controller = ReadinessController(
    systemService: SystemService(bridge: fake),
    bridge: fake,
  );
  await controller.refresh();
  var skipped = false;
  await tester.pumpWidget(
    MaterialApp(
      home: OnboardingPage(
        controller: controller,
        onSkipToSettings: () => skipped = true,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller, () => skipped);
}

void main() {
  setUp(() {
    // Clipboard 走 platform channel；测试环境置空处理器避免 MissingPlugin。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });

  testWidgets('Missing Docker CLI explains installation and rechecks', (
    tester,
  ) async {
    final (controller, _) = await _pumpOnboarding(
      tester,
      FakeContainerBridge()..binaryPath = null,
    );
    expect(find.text('配置 Docker 连接'), findsOneWidget);
    expect(find.textContaining('DOCKER_HOST'), findsOneWidget);
    expect(find.text(kContainerReleaseUrl), findsOneWidget);
    await tester.tap(find.text('重新检查'));
    await tester.pumpAndSettle();
    expect(controller.readiness!.ready, isFalse);
  });
  testWidgets('Independent Docker versions are accepted', (tester) async {
    final (controller, _) = await _pumpOnboarding(
      tester,
      FakeContainerBridge()
        ..versionResult = const BridgeCommandResult(
          exitCode: 0,
          stdout:
              '{"Client":{"Version":"30.0.0"},"Server":{"Version":"28.0.0"}}',
          stderr: '',
        ),
    );
    expect(controller.readiness!.ready, isTrue);
    expect(find.textContaining('底层引擎不限'), findsOneWidget);
  });
  testWidgets('跳过出口回调生效', (tester) async {
    final (_, skipped) = await _pumpOnboarding(
      tester,
      FakeContainerBridge()..binaryPath = null,
    );
    await tester.tap(find.text('跳过并仅查看设置'));
    await tester.pumpAndSettle();
    expect(skipped(), isTrue);
  });
}
