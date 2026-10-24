/// lib/ui/ 共享组件的 widget 测试（P0，issue #26）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ghost_container_manager/ui/colors.dart';
import 'package:ghost_container_manager/ui/components.dart';
import 'package:ghost_container_manager/ui/text.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('GcmColors', () {
    test('状态色语义映射运行/停止/合成/失败/未知', () {
      expect(GcmColors.stateRunning, const Color(0xFF1D7A34));
      expect(GcmColors.stateTransition, const Color(0xFF8A6D00));
      // stopped/unknown 走 outline 语义，由 context 解析；此处验证映射函数存在。
      expect(GcmColors.stateColor('running'), GcmColors.stateRunning);
      expect(GcmColors.stateColor('stopping'), GcmColors.stateTransition);
      expect(GcmColors.stateColor('failed'), isNot(GcmColors.stateRunning));
    });
  });

  group('SectionCard', () {
    testWidgets('渲染标题与内容区', (tester) async {
      await tester.pumpWidget(
        _wrap(const SectionCard(title: '镜像列表', child: Text('内容'))),
      );
      expect(find.text('镜像列表'), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('可选操作行渲染在标题行', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SectionCard(
            title: '配置',
            actions: [TextButton(onPressed: () {}, child: const Text('编辑'))],
            child: const Text('内容'),
          ),
        ),
      );
      expect(find.text('编辑'), findsOneWidget);
    });
  });

  group('CopyValue', () {
    testWidgets('显示标识值并可复制', (tester) async {
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      await tester.pumpWidget(_wrap(const CopyValue(value: 'abc123def')));
      expect(find.text('abc123def'), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy-value-abc123def')));
      await tester.pump();
      expect(clipboard, 'abc123def');
    });

    testWidgets('display 覆盖显示但复制原值', (tester) async {
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      await tester.pumpWidget(
        _wrap(const CopyValue(value: 'full-value', display: 'full…')),
      );
      expect(find.text('full…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy-value-full-value')));
      await tester.pump();
      expect(clipboard, 'full-value');
    });
  });

  group('MaskedValue', () {
    testWidgets('默认打码，切换显示明文', (tester) async {
      await tester.pumpWidget(_wrap(const MaskedValue(value: 'secret-token')));
      expect(find.text('secret-token'), findsNothing);
      expect(find.textContaining('⦿'), findsOneWidget);
      await tester.tap(find.byKey(const Key('masked-toggle-secret-token')));
      await tester.pump();
      expect(find.text('secret-token'), findsOneWidget);
    });
  });

  group('StateDot', () {
    testWidgets('运行态用语义运行色', (tester) async {
      await tester.pumpWidget(_wrap(const StateDot(state: 'running')));
      final dot = tester.widget<Container>(find.byKey(const Key('state-dot')));
      final decoration = dot.decoration as BoxDecoration?;
      expect(decoration?.color, GcmColors.stateRunning);
    });
  });

  group('SidebarSection / CountBadge', () {
    testWidgets('分组标题渲染', (tester) async {
      await tester.pumpWidget(_wrap(const SidebarSection(title: '工作')));
      expect(find.text('工作'), findsOneWidget);
    });

    testWidgets('计数徽章显示数量', (tester) async {
      await tester.pumpWidget(_wrap(const CountBadge(count: 3)));
      expect(find.text('3'), findsOneWidget);
    });
  });

  group('text helpers', () {
    test('formatBytes / formatDuration', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536 * 1024), '1.5 MB');
      expect(formatDuration(const Duration(seconds: 65)), contains('1'));
    });
  });
}
