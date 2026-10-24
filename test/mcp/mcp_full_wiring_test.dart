import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/settings/mcp_settings_controller.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/mount_service.dart';
import 'package:ghost_container_manager/services/network_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// P2 full-wiring evidence: with every service domain handed to
/// [GcmMcpServer], `tools/list` exposes the complete v1 surface
/// (system/container/image/mount/network/compose), and the settings
/// controller starts the server on launch when enabled.
void main() {
  late FakeContainerBridge bridge;
  late SystemService systemService;
  late ContainerService containerService;
  late ImageService imageService;
  late MountService mountService;
  late NetworkService networkService;
  late ComposeService composeService;

  setUp(() {
    bridge = FakeContainerBridge();
    systemService = SystemService(bridge: bridge, pingInterval: Duration.zero);
    containerService = ContainerService(bridge: bridge);
    imageService = ImageService(
      bridge: bridge,
      containerService: containerService,
    );
    mountService = MountService(containerService: containerService);
    networkService = NetworkService(
      bridge: bridge,
      containerService: containerService,
    );
    composeService = ComposeService(
      bridge: bridge,
      containerService: containerService,
    );
  });

  GcmMcpServer makeServer() => GcmMcpServer(
    systemService: systemService,
    containerService: containerService,
    imageService: imageService,
    mountService: mountService,
    networkService: networkService,
    composeService: composeService,
    port: 0,
    enableJsonResponse: true,
  );

  test('tools/list exposes exactly 24 v1 tools across six domains', () async {
    final server = makeServer();
    await server.start();
    addTearDown(server.stop);

    final http = HttpClient();
    addTearDown(http.close);

    Future<(Map<String, dynamic>?, String?, String?)> rpc(
      Map<String, dynamic> message, {
      String? sessionId,
      String? protocolVersion,
    }) async {
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${server.boundPort}/mcp'),
      );
      request.headers
        ..set('content-type', 'application/json')
        ..set('accept', 'application/json, text/event-stream');
      if (sessionId != null) request.headers.set('mcp-session-id', sessionId);
      if (protocolVersion != null) {
        request.headers.set('mcp-protocol-version', protocolVersion);
      }
      request.write(jsonEncode(message));
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return (
        body.trim().isEmpty ? null : jsonDecode(body) as Map<String, dynamic>,
        response.headers.value('mcp-session-id'),
        response.headers.value('mcp-protocol-version'),
      );
    }

    final (initBody, sessionId, _) = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{
          'name': 'wiring-test',
          'version': '0.0.0',
        },
      },
    });
    expect(initBody?['result'], isNotNull);
    final negotiatedVersion =
        (initBody!['result'] as Map<String, dynamic>)['protocolVersion']
            as String?;

    // notifications/initialized（必须先于 tools/list）。
    await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
      sessionId: sessionId,
      protocolVersion: negotiatedVersion,
    );

    final (listBody, _, _) = await rpc(
      <String, dynamic>{'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      sessionId: sessionId,
      protocolVersion: negotiatedVersion,
    );
    final tools = (listBody?['result'] as Map)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name'] as String).toSet();

    const expected = {
      'system_status',
      'system_start',
      'system_stop',
      'container_list',
      'container_inspect',
      'container_stats',
      'container_create',
      'container_start',
      'container_stop',
      'container_restart',
      'container_delete',
      'container_kill',
      'container_exec',
      'image_list',
      'image_inspect',
      'image_delete',
      'image_pull',
      'mount_list',
      'mount_inspect',
      'network_list',
      'network_get',
      'compose_list',
      'compose_up',
      'compose_down',
    };
    expect(names, hasLength(24), reason: 'unexpected tools: $names');
    expect(
      names,
      expected,
      reason:
          'missing: ${expected.difference(names)}; '
          'unexpected: ${names.difference(expected)}',
    );
  });

  test('settings switch on launch starts the server; off stops it', () async {
    final controller = McpSettingsController(
      systemService: systemService,
      containerService: containerService,
      imageService: imageService,
      mountService: mountService,
      networkService: networkService,
      composeService: composeService,
    )..port = 0;

    // 启动时按设置开关拉起（enabled 默认 true）。
    await controller.sync();
    expect(controller.running, isTrue, reason: controller.lastError ?? '');
    expect(controller.boundPort, isNotNull);
    expect(controller.boundPort, isNot(0));

    // 关闭开关停止服务。
    await controller.setEnabled(false);
    expect(controller.running, isFalse);
    expect(controller.boundPort, isNull);

    // 重新打开再次拉起。
    await controller.setEnabled(true);
    expect(controller.running, isTrue, reason: controller.lastError ?? '');

    await controller.setEnabled(false);
  });
}
