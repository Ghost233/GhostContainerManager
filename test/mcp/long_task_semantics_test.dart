import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../services/container_service_test.dart' show snapshotPayload;

/// issue #32 长任务核对结论（审计为主，补缺不重建）。
///
/// ## gcm_call 分发透传
/// lib/mcp/tools/catalog_tools.dart 的 gcm_call handler 把
/// [RequestHandlerExtra] **原样**传给业务 callback（不重建 extra），因此
/// mcp_dart 2.4.3 提供的 `signal`（取消）、`meta['progressToken']`（进度）、
/// `sessionId`/`requestId`（调用元信息）全部天然透传。本文件用直调
/// callback 的方式核对业务侧对这些上下文的消费。
///
/// ## 进度通知
/// 已接线：image_pull、project_build/test/publish/restore、registry_start
/// （均以 progressToken 存在为门槛；客户端没给 token 时只记 warn 不发通知，
/// 见 mcp_dart protocol.dart sendProgress）。
/// 已知限制：system_start（含内核下载）无进度通知——CLI 路由不提供结构化
/// 进度流，属非小修缺口，记录于交付回报。compose_up/down 无进度是规格
/// §6 明确例外，不算缺口。
///
/// ## 取消
/// 已接线：image_pull（signal.onAbort → ImageService.cancelPull）、
/// project_build/test/publish/restore（_withCancellation 桥接）、
/// registry_start。已知限制：container 生命周期操作与 compose/system
/// 无客户端取消（container_stop 不可取消是规格设计）。
///
/// ## 超时
/// 仅 container_exec 有 MCP 侧超时（默认 60s，见
/// lib/mcp/tools/container_tools.dart）；其余工具依赖底层运行时/CLI，
/// 无 MCP 侧超时——记录为已知限制。
///
/// ## 「已停止 / 仍在执行 / 状态未知」的区分
/// - 客户端停等（client-side timeout、连接断开但无 cancelled 通知）≠
///   后台已取消：signal 不触发，操作继续跑完，绝不报告为已取消（下方
///   「无取消信号」测试钉住这一点）。
/// - 显式取消（cancelled 通知 / signal.abort）才走运行时取消路由；
///   取消后运行时状态**未知**（上游无服务端取消确认，见
///   ImageService.pull 的 cancel 语义注释），查询途径：镜像用
///   image_list/image_inspect，容器用 container_inspect。
/// - exec 超时=放弃等待，进程可能仍在容器内运行（上游
///   apple/container#1941，exec 进程无可靠 kill 路由）；TIMEOUT 错误的
///   hint 必须带容器 id 对应的查询方法（下方超时测试钉住）。
void main() {
  late FakeContainerBridge bridge;
  late SystemService systemService;
  late ContainerService containerService;
  late ImageService imageService;
  late ToolCallbackRegistry registry;

  setUp(() {
    bridge = FakeContainerBridge()..containers = [snapshotPayload(id: 'web')];
    systemService = SystemService(bridge: bridge, pingInterval: Duration.zero);
    containerService = ContainerService(bridge: bridge);
    imageService = ImageService(
      bridge: bridge,
      containerService: containerService,
    );
    registry = buildBusinessToolRegistry(
      systemService: systemService,
      containerService: containerService,
      imageService: imageService,
    );
  });

  RequestHandlerExtra makeExtra({
    AbortSignal? signal,
    Map<String, dynamic>? meta,
    List<JsonRpcNotification>? notifications,
  }) => RequestHandlerExtra(
    signal: signal ?? BasicAbortController().signal,
    requestId: 1,
    meta: meta,
    sendNotification: (notification, {relatedTask}) async {
      notifications?.add(notification);
    },
    sendRequest: <T extends BaseResultData>(request, resultFactory, options) =>
        throw UnimplementedError('sendRequest 不在这些工具的核对范围内'),
  );

  group('超时（exec）', () {
    test('container_exec 超时：TIMEOUT 含容器 id 与查询方法（状态未知语义）', () async {
      bridge.execResult = const BridgeExecResult(
        exitCode: -1,
        stdout: '',
        stderr: '',
        timedOut: true,
      );
      final result = await registry.callbacks['container_exec']!(
        <String, dynamic>{
          'id': 'web',
          'command': <String>['sleep', '600'],
        },
        makeExtra(),
      );
      expect(result.isError, isTrue);
      final error = result.structuredContent!['error'] as Map<String, dynamic>;
      expect(error['code'], 'TIMEOUT');
      // 资源标识 + 查询方法：超时不等于进程已停止。
      expect(error['message'], contains('web'));
      expect(error['hint'], contains('container_inspect'));
    });
  });

  group('取消透传（image_pull）', () {
    test('显式 abort 透传到运行时取消路由', () async {
      bridge.pullHangs = true;
      final abortController = BasicAbortController();
      final resultFuture = registry.callbacks['image_pull']!(<String, dynamic>{
        'reference': 'docker.io/library/alpine:3.20',
      }, makeExtra(signal: abortController.signal));
      await pumpEventQueue(); // 让 pull 进入在飞状态
      expect(bridge.pullCalls, hasLength(1));

      abortController.abort();
      final result = await resultFuture;

      // 取消信号已透传到运行时取消路由。
      expect(bridge.pullCancelCalls, hasLength(1));
      // 直调路径下 AbortError 被 guardToolCall 包成 internal 错误；真实协议
      // 路径中客户端已取消，该响应被协议层丢弃（见 image_tools.dart 注释
      // 「Client-aborted pulls never see this result」）。无论哪条路径，
      // 都不会产出「拉取已完成」的误导性结果。
      expect(result.isError, isTrue);
    });

    test('无取消信号时正常完成，不触发运行时取消（客户端停等≠已取消）', () async {
      final result = await registry.callbacks['image_pull']!(<String, dynamic>{
        'reference': 'docker.io/library/alpine:3.20',
      }, makeExtra());
      expect(result.isError, isNot(true));
      // 没有任何 cancel 副作用：客户端停止等待（不发 cancelled 通知）时
      // 操作照常跑完，绝不能被报告为后台已取消。
      expect(bridge.pullCancelCalls, isEmpty);
    });
  });

  group('进度透传（image_pull）', () {
    test('progressToken 存在时进度通知带 token 发出', () async {
      final blocker = Completer<void>();
      bridge.pullBlocker = blocker;
      final notifications = <JsonRpcNotification>[];
      final resultFuture = registry.callbacks['image_pull']!(
        <String, dynamic>{'reference': 'docker.io/library/alpine:3.20'},
        makeExtra(
          meta: <String, dynamic>{'progressToken': 'pt-issue32'},
          notifications: notifications,
        ),
      );
      await pumpEventQueue(); // pull 在飞，事件订阅已挂上
      final pullId = bridge.pullCalls.single.split(' ').first;

      bridge.pullEventsController.add(
        BridgeImagePullEvent(
          pullId: pullId,
          description: '下载层 1/2',
          completedBytes: 50,
          totalBytes: 100,
        ),
      );
      await pumpEventQueue(); // 通知是 unawaited 发出的
      blocker.complete();
      final result = await resultFuture;

      expect(result.isError, isNot(true));
      final progress = notifications.whereType<JsonRpcProgressNotification>();
      expect(progress, isNotEmpty);
      expect(progress.first.progressParams.progressToken, 'pt-issue32');
      expect(progress.first.progressParams.progress, 0.5);
    });

    test('无 progressToken 时不发进度通知（不炸不阻塞）', () async {
      final notifications = <JsonRpcNotification>[];
      final result = await registry.callbacks['image_pull']!(<String, dynamic>{
        'reference': 'docker.io/library/alpine:3.20',
      }, makeExtra(notifications: notifications));
      expect(result.isError, isNot(true));
      expect(notifications, isEmpty);
    });
  });
}
