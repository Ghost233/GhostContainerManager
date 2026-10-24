import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tools/compose_tools.dart';
import 'package:ghost_container_manager/mcp/tools/mount_tools.dart';
import 'package:ghost_container_manager/mcp/tools/network_tools.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/mount_service.dart';
import 'package:ghost_container_manager/services/network_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../services/container_service_test.dart' show snapshotPayload;

/// One container with a mount and compose labels (CLI 1.5.0 wire shape).
Map<String, Object?> shopWebPayload() {
  final payload = snapshotPayload(
    id: 'shop-web',
    labels: const {'com.compose.project': 'shop', 'com.compose.service': 'web'},
  );
  (payload['configuration']
      as Map<String, Object?>)['mounts'] = <Map<String, Object?>>[
    <String, Object?>{
      'destination': '/usr/share',
      'options': <String>['ro'],
      'source': '/Users/x/site',
      'type': <String, Object?>{'virtiofs': <String, Object?>{}},
    },
  ];
  return payload;
}

const _networkListJson =
    '[{"configuration":{"name":"default","mode":"nat","plugin":"builtin",'
    '"labels":{"com.apple.container.resource.role":"builtin"}},'
    '"status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}}]';

/// End-to-end evidence for issue #21 acceptance 3: the seven T6 tools
/// (mount_list/mount_inspect/network_list/network_get/compose_up/
/// compose_down/compose_list) are served over Streamable HTTP by a
/// self-built McpServer (lead wires them into GcmMcpServer centrally).
void main() {
  late FakeContainerBridge bridge;
  late StreamableMcpServer transport;
  final http = HttpClient();

  String? sessionId;
  String? protocolVersion;

  Uri endpoint() => Uri.parse('http://127.0.0.1:${transport.boundPort}/mcp');

  setUp(() async {
    sessionId = null;
    protocolVersion = null;
    bridge = FakeContainerBridge()
      ..containers = [shopWebPayload()]
      ..networkListResult = const BridgeCommandResult(
        exitCode: 0,
        stdout: _networkListJson,
        stderr: '',
      );
    final containerService = ContainerService(bridge: bridge);
    transport = StreamableMcpServer(
      serverFactory: (_) {
        final server = McpServer(
          const Implementation(name: 't6-tools-test', version: '0'),
        );
        registerMountTools(
          server,
          MountService(containerService: containerService),
        );
        registerNetworkTools(
          server,
          NetworkService(bridge: bridge, containerService: containerService),
        );
        registerComposeTools(
          server,
          ComposeService(bridge: bridge, containerService: containerService),
        );
        return server;
      },
      host: '127.0.0.1',
      port: 0,
      path: '/mcp',
      enableJsonResponse: true,
    );
    await transport.start();
  });

  tearDown(() async {
    await transport.stop();
  });

  Future<Map<String, dynamic>> rpc(Map<String, dynamic> message) async {
    final request = await http.postUrl(endpoint());
    request.headers
      ..set('content-type', 'application/json')
      ..set('accept', 'application/json, text/event-stream');
    if (sessionId != null) request.headers.set('mcp-session-id', sessionId!);
    if (protocolVersion != null) {
      request.headers.set('mcp-protocol-version', protocolVersion!);
    }
    request.write(jsonEncode(message));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    expect(response.statusCode, inInclusiveRange(200, 202));
    sessionId ??= response.headers.value('mcp-session-id');
    return body.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> initialize() async {
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{'name': 't6-e2e', 'version': '0'},
      },
    });
    protocolVersion =
        (body['result'] as Map<String, dynamic>)['protocolVersion'] as String?;
    await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 99,
      'method': 'tools/call',
      'params': <String, dynamic>{'name': name, 'arguments': arguments},
    });
    return body['result'] as Map<String, dynamic>;
  }

  test('tools/list exposes all seven T6 tools', () async {
    await initialize();
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = (body['result'] as Map<String, dynamic>)['tools'] as List;
    final byName = <String, Map<String, dynamic>>{
      for (final t in tools) (t as Map)['name'] as String: t.cast(),
    };
    const expectedTitles = <String, String>{
      'mount_list': 'List Mounts',
      'mount_inspect': 'Inspect Mount',
      'network_list': 'List Networks',
      'network_get': 'Get Network',
      'compose_list': 'List Compose Projects',
      'compose_up': 'Compose Up',
      'compose_down': 'Compose Down',
    };
    expect(byName.keys, containsAll(expectedTitles.keys));
    for (final entry in expectedTitles.entries) {
      expect(byName[entry.key]?['title'], entry.value, reason: entry.key);
    }
  });

  test('mount_list returns structuredContent plus a Chinese summary', () async {
    await initialize();
    final result = await callTool('mount_list', <String, dynamic>{});

    expect(result['isError'], isNot(true));
    final data = result['structuredContent'] as Map<String, dynamic>;
    final mounts = data['mounts'] as List;
    expect(mounts, hasLength(1));
    expect((mounts.single as Map)['name'], '/Users/x/site');
    final summary =
        ((result['content'] as List).single as Map)['text'] as String;
    expect(summary, contains('个挂载源'));
  });

  test('mount_inspect unknown name → isError with NOT_FOUND wire', () async {
    await initialize();
    final result = await callTool('mount_inspect', <String, dynamic>{
      'name': '/nope',
    });

    expect(result['isError'], isTrue);
    final error =
        (result['structuredContent'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'NOT_FOUND');
  });

  test('network_list and network_get join member containers', () async {
    await initialize();

    final list = await callTool('network_list', <String, dynamic>{});
    final networks =
        (list['structuredContent'] as Map<String, dynamic>)['networks'] as List;
    final defaultNetwork = networks.single as Map<String, dynamic>;
    expect(defaultNetwork['id'], 'default');
    expect(defaultNetwork['builtin'], isTrue);
    expect(defaultNetwork['containerCount'], 1);

    final detail = await callTool('network_get', <String, dynamic>{
      'id': 'default',
    });
    final containers =
        (detail['structuredContent'] as Map<String, dynamic>)['containers']
            as List;
    expect((containers.single as Map)['id'], 'shop-web');
  });

  test('compose_list aggregates projects from labels', () async {
    await initialize();
    final result = await callTool('compose_list', <String, dynamic>{});

    final projects =
        (result['structuredContent'] as Map<String, dynamic>)['projects']
            as List;
    final shop = projects.single as Map<String, dynamic>;
    expect(shop['name'], 'shop');
    expect(shop['runningCount'], 1);
  });

  test('compose_up dry-run passes plugin text through', () async {
    await initialize();
    bridge.composeRunScript = [
      const BridgeCommandResult(
        exitCode: 0,
        stdout: 'plan: would create container shop-web',
        stderr: '',
      ),
    ];

    final result = await callTool('compose_up', <String, dynamic>{
      'file': '/tmp/compose.yaml',
      'projectName': 'shop',
      'dryRun': true,
    });

    expect(result['isError'], isNot(true));
    final data = result['structuredContent'] as Map<String, dynamic>;
    expect(data['exitCode'], 0);
    expect(data['output'], contains('would create container shop-web'));
    expect(data['truncated'], isFalse);
    expect(
      bridge.calls,
      contains(
        'composeRun up --file /tmp/compose.yaml --project-name shop '
        '--dry-run --pull missing',
      ),
    );
  });

  test('compose_up relative file → INVALID_ARGUMENT tool error', () async {
    await initialize();
    final result = await callTool('compose_up', <String, dynamic>{
      'file': 'compose.yaml',
    });

    expect(result['isError'], isTrue);
    final error =
        (result['structuredContent'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'INVALID_ARGUMENT');
  });

  test('compose_down requires file or projectName', () async {
    await initialize();
    final result = await callTool('compose_down', <String, dynamic>{});

    expect(result['isError'], isTrue);
    final error =
        (result['structuredContent'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'INVALID_ARGUMENT');
  });
}
