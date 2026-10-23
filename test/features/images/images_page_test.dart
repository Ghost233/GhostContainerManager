import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/images/images_page.dart';
import 'package:ghost_container_manager/features/system/readiness_controller.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

Map<String, Object?> imagePayload({
  required String reference,
  int sizeBytes = 4096,
  String? createdAt = '2026-10-20T08:00:00Z',
}) {
  return <String, Object?>{
    'reference': reference,
    'digest': 'sha256:${'a' * 64}',
    'mediaType': 'application/vnd.oci.image.index.v1+json',
    'sizeBytes': sizeBytes,
    'createdAt': ?createdAt,
  };
}

/// 与 test/features/containers/containers_page_test.dart 相同的 harness：
/// fake 默认就绪（1.6.0/running/内核在），refresh 后页面进数据态。
Future<(FakeContainerBridge, ImageService)> _pumpPage(
  WidgetTester tester,
  FakeContainerBridge fake,
) async {
  final readiness = ReadinessController(
    systemService: SystemService(bridge: fake),
    bridge: fake,
  );
  await readiness.refresh();
  final service = ImageService(bridge: fake);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ImagesPage(
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

void main() {
  group('ImagesPage 列表', () {
    testWidgets('展示镜像行、悬空标记与计数', (tester) async {
      final fake = FakeContainerBridge()
        ..images = <Map<String, Object?>>[
          imagePayload(reference: 'docker.io/library/alpine:3.19'),
          imagePayload(reference: 'docker.io/library/oldbase', sizeBytes: 2048),
        ];
      await _pumpPage(tester, fake);

      expect(find.text('docker.io/library/alpine:3.19'), findsOneWidget);
      expect(find.text('docker.io/library/oldbase:<none>'), findsOneWidget);
      expect(find.text('悬空'), findsOneWidget);
      expect(find.text('共 2 个镜像（悬空 1）'), findsOneWidget);
    });

    testWidgets('搜索框过滤列表', (tester) async {
      final fake = FakeContainerBridge()
        ..images = <Map<String, Object?>>[
          imagePayload(reference: 'docker.io/library/alpine:3.19'),
          imagePayload(reference: 'docker.io/library/nginx:latest'),
        ];
      await _pumpPage(tester, fake);

      await tester.enterText(find.byType(TextField).first, 'nginx');
      await tester.pump();

      expect(find.text('docker.io/library/nginx:latest'), findsOneWidget);
      expect(find.text('docker.io/library/alpine:3.19'), findsNothing);
    });

    testWidgets('空态展示引导与主操作', (tester) async {
      await _pumpPage(tester, FakeContainerBridge());

      expect(find.text('暂无镜像，拉取一个开始使用'), findsOneWidget);
      // 工具栏与空态各有一个「拉取镜像」主操作。
      expect(find.widgetWithText(FilledButton, '拉取镜像'), findsNWidgets(2));
    });
  });

  group('ImagesPage 详情', () {
    testWidgets('点行进详情展示 inspect 配置摘要并可返回', (tester) async {
      const reference = 'docker.io/library/alpine:3.19';
      final fake = FakeContainerBridge()
        ..images = <Map<String, Object?>>[imagePayload(reference: reference)]
        ..imageInspectResponses[reference] = <String, Object?>{
          'reference': reference,
          'digest': 'sha256:${'a' * 64}',
          'sizeBytes': 8192,
          'layers': 3,
          'platforms': <Object?>['linux/arm64'],
          'config': <String, Object?>{
            'env': <Object?>['PATH=/usr/bin'],
            'entrypoint': <Object?>['/entry.sh'],
            'cmd': <Object?>['--serve'],
            'exposedPorts': <Object?>['8080/tcp'],
            'labels': <String, Object?>{'com.ghost233.project': 'demo'},
          },
        };
      await _pumpPage(tester, fake);

      await tester.tap(find.text(reference));
      await tester.pumpAndSettle();

      expect(find.text('入口命令'), findsOneWidget);
      expect(find.text('/entry.sh --serve'), findsOneWidget);
      expect(find.text('8080/tcp'), findsOneWidget);
      expect(find.text('PATH=/usr/bin'), findsOneWidget);
      expect(find.text('com.ghost233.project=demo'), findsOneWidget);

      await tester.tap(find.text('返回镜像列表'));
      await tester.pumpAndSettle();
      expect(find.text('共 1 个镜像（悬空 0）'), findsOneWidget);
    });
  });

  group('ImagesPage 删除', () {
    testWidgets('确认删除后镜像消失', (tester) async {
      const reference = 'docker.io/library/alpine:3.19';
      final fake = FakeContainerBridge()
        ..images = <Map<String, Object?>>[imagePayload(reference: reference)];
      await _pumpPage(tester, fake);

      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除镜像'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(fake.deletedImages, [reference]);
      expect(find.text('暂无镜像，拉取一个开始使用'), findsOneWidget);
    });

    testWidgets('取消确认则不调用删除', (tester) async {
      const reference = 'docker.io/library/alpine:3.19';
      final fake = FakeContainerBridge()
        ..images = <Map<String, Object?>>[imagePayload(reference: reference)];
      await _pumpPage(tester, fake);

      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(fake.deletedImages, isEmpty);
      expect(find.text(reference), findsOneWidget);
    });

    testWidgets('删除被占用镜像展示错误码与提示', (tester) async {
      const reference = 'docker.io/library/alpine:3.19';
      final fake = FakeContainerBridge()
        ..images = <Map<String, Object?>>[imagePayload(reference: reference)]
        ..imageDeleteFailures[reference] =
            'image with reference $reference is in use by container web';
      await _pumpPage(tester, fake);

      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(find.text('删除失败'), findsOneWidget);
      expect(find.textContaining('CONFLICT'), findsOneWidget);
    });
  });

  group('ImagesPage 拉取', () {
    testWidgets('拉取进度实时更新、完成后关闭并刷新列表', (tester) async {
      final fake = FakeContainerBridge()..pullBlocker = Completer<void>();
      await _pumpPage(tester, fake);

      await tester.tap(find.text('拉取镜像').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '镜像引用').first,
        'alpine:3.19',
      );
      await tester.tap(find.widgetWithText(FilledButton, '拉取'));
      await tester.pump();

      // 从 fake 记录的调用中取出页面生成的 pullId。
      expect(fake.pullCalls, hasLength(1));
      final pullId = fake.pullCalls.first.split(' ').first;

      fake.pullEventsController.add(
        BridgeImagePullEvent(
          pullId: pullId,
          description: '下载层',
          completedBytes: 1024,
          totalBytes: 4096,
        ),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('下载层'), findsOneWidget);
      expect(find.textContaining('1.0 KB / 4.0 KB'), findsOneWidget);

      fake.pullBlocker!.complete();
      // 拉取收尾链（fake 闸门 → service 退订 → 弹窗 pop）跑在真实事件循环
      // 里更确定；fake-async 泵不出这条跨 Completer 的微任务链。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      // 对话框关闭且列表已刷新出新镜像（引用为归一化后的 name:tag）。
      expect(find.text('拉取镜像'), findsWidgets);
      expect(find.text('alpine:3.19'), findsOneWidget);
    });

    testWidgets('取消拉取关闭对话框且调用 imagePullCancel', (tester) async {
      final fake = FakeContainerBridge()..pullHangs = true;
      await _pumpPage(tester, fake);

      await tester.tap(find.text('拉取镜像').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '镜像引用').first,
        'alpine:3.19',
      );
      await tester.tap(find.widgetWithText(FilledButton, '拉取'));
      await tester.pump();

      await tester.tap(find.text('取消拉取'));
      // 同上：取消闸门收尾走真实事件循环，再泵弹窗关闭动画。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(fake.pullCancelCalls, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
