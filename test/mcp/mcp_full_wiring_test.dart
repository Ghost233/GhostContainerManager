import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/features/settings/mcp_settings_controller.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/mount_service.dart';
import 'package:ghost_container_manager/services/network_service.dart';
import 'package:ghost_container_manager/services/project_service.dart';
import 'package:ghost_container_manager/services/registry_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// Minimal ProjectCli fake for wiring tests (T7 logic is covered by its own
/// suites; here we only need construction to succeed).
class _FakeProjectCli implements ProjectCli {
  @override
  Future<BridgeCommandResult> run(List<String> args, {Duration? timeout}) =>
      Future.value(
        const BridgeCommandResult(exitCode: 0, stdout: '', stderr: ''),
      );

  @override
  ProjectCliProcess start(List<String> args) => _FakeProjectCliProcess();
}

class _FakeProjectCliProcess implements ProjectCliProcess {
  @override
  Stream<String> get stdoutLines => const Stream.empty();

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  void terminate() {}
}

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
  late ProjectService projectService;
  late RegistryService registryService;

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
    projectService = ProjectService(
      cli: _FakeProjectCli(),
      containerService: containerService,
      imageService: imageService,
    );
    registryService = RegistryService(
      containers: containerService,
      images: imageService,
      cli: _FakeProjectCli(),
    );
  });

  GcmMcpServer makeServer() => GcmMcpServer(
    systemService: systemService,
    containerService: containerService,
    imageService: imageService,
    mountService: mountService,
    networkService: networkService,
    composeService: composeService,
    projectService: projectService,
    registryService: registryService,
    port: 0,
    enableJsonResponse: true,
  );

  test('tools/list exposes the slim two-tool surface; gcm_help catalogs all 35 v1 tools', () async {
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
    // 精简注册模式（2026-10-26 用户拍板）：tools/list 只暴露两个入口工具。
    expect(names, <String>{'gcm_help', 'gcm_call'});

    final (helpBody, _, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'gcm_help',
          'arguments': <String, dynamic>{},
        },
      },
      sessionId: sessionId,
      protocolVersion: negotiatedVersion,
    );
    final structured =
        (helpBody?['result'] as Map)['structuredContent']
            as Map<String, dynamic>;
    final domains = structured['domains'] as Map<String, dynamic>;
    final catalogNames = <String>{
      for (final domainTools in domains.values)
        for (final tool in domainTools as List) (tool as Map)['name'] as String,
    };

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
      'project_list',
      'project_get',
      'project_init',
      'project_build',
      'project_test',
      'project_reclaim',
      'project_publish',
      'project_restore',
      'registry_status',
      'registry_start',
      'registry_stop',
    };
    expect(catalogNames, hasLength(35), reason: 'catalog: $catalogNames');
    expect(
      catalogNames,
      expected,
      reason:
          'missing: ${expected.difference(catalogNames)}; '
          'unexpected: ${catalogNames.difference(expected)}',
    );
    expect(structured['totalTools'], 35);
  });

  test('settings switch on launch starts the server; off stops it', () async {
    final controller = McpSettingsController(
      systemService: systemService,
      containerService: containerService,
      imageService: imageService,
      mountService: mountService,
      networkService: networkService,
      composeService: composeService,
      projectService: projectService,
      registryService: registryService,
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
