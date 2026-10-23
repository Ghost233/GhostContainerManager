import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

import '../services/container_service_test.dart' show snapshotPayload;

/// End-to-end evidence for issue #17 acceptance 4: an MCP client speaking
/// Streamable HTTP calls container_list / container_inspect / container_stats
/// and gets structuredContent plus a text summary; label filtering and the
/// two-layer error model are exercised against the fake bridge.
void main() {
  late FakeContainerBridge bridge;
  late GcmMcpServer server;
  final http = HttpClient();

  String? sessionId;
  String? protocolVersion;

  Uri endpoint() => Uri.parse('http://127.0.0.1:${server.boundPort}/mcp');

  setUp(() async {
    sessionId = null;
    protocolVersion = null;
    bridge = FakeContainerBridge()
      ..containers = [
        snapshotPayload(
          id: 'web',
          labels: const {'com.ghost233.compose.project': 'shop'},
        ),
        snapshotPayload(
          id: 'db',
          status: 'stopped',
          startedAt: null,
          labels: const {'com.ghost233.compose.project': 'shop'},
        ),
        snapshotPayload(
          id: 'other',
          labels: const {'com.ghost233.compose.project': 'blog'},
        ),
      ];
    server = GcmMcpServer(
      systemService: SystemService(bridge: bridge, pingInterval: Duration.zero),
      containerService: ContainerService(bridge: bridge),
      port: 0,
      enableJsonResponse: true,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
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
        'clientInfo': <String, dynamic>{
          'name': 'container-e2e',
          'version': '0',
        },
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

  test('tools/list 含容器只读工具', () async {
    await initialize();
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = (body['result'] as Map<String, dynamic>)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name']).toSet();
    expect(
      names,
      containsAll(['container_list', 'container_inspect', 'container_stats']),
    );
    expect(names, isNot(contains('container_logs'))); // #13: UI 专属
  });

  test('container_list 返回 structuredContent + 文本摘要', () async {
    await initialize();
    final result = await callTool('container_list', <String, dynamic>{});

    expect(result['isError'], isNot(true));
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final containers = structured['containers'] as List;
    expect(containers, hasLength(3));
    final web = containers.firstWhere((c) => (c as Map)['id'] == 'web') as Map;
    expect(web['name'], 'web');
    expect(web['status'], 'running');
    expect((web['networks'] as List).single['ip'], '192.168.64.3');
    final content = result['content'] as List;
    expect((content.first as Map)['text'], contains('共 3 个容器'));
  });

  test('container_list label 精确过滤', () async {
    await initialize();
    final result = await callTool('container_list', <String, dynamic>{
      'label': 'com.ghost233.compose.project=shop',
    });
    final containers =
        (result['structuredContent'] as Map<String, dynamic>)['containers']
            as List;
    expect(containers.map((c) => (c as Map)['id']), containsAll(['web', 'db']));
    expect(containers, hasLength(2));
  });

  test('container_list all=false 只返回运行中', () async {
    await initialize();
    final result = await callTool('container_list', <String, dynamic>{
      'all': false,
    });
    final containers =
        (result['structuredContent'] as Map<String, dynamic>)['containers']
            as List;
    expect(containers.map((c) => (c as Map)['id']), ['web', 'other']);
  });

  test('container_inspect 返回完整 configuration', () async {
    await initialize();
    final result = await callTool('container_inspect', <String, dynamic>{
      'id': 'web',
    });
    final container =
        (result['structuredContent'] as Map<String, dynamic>)['container']
            as Map<String, dynamic>;
    expect(container['stopSignal'], 'SIGTERM');
    expect(container['environment'], ['A=1', 'B=2']);
    expect((container['configuration'] as Map)['id'], 'web');
  });

  test('container_inspect 未知 id → isError + NOT_FOUND', () async {
    await initialize();
    final result = await callTool('container_inspect', <String, dynamic>{
      'id': 'ghost',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'NOT_FOUND');
    expect((structured['error'] as Map)['hint'], isNotNull);
  });

  test('container_stats 返回快照结构', () async {
    await initialize();
    final result = await callTool('container_stats', <String, dynamic>{
      'id': 'web',
    });
    expect(result['isError'], isNot(true));
    final stats =
        (result['structuredContent'] as Map<String, dynamic>)['stats']
            as Map<String, dynamic>;
    expect(stats['id'], 'web');
    expect(stats['memoryUsageBytes'], 64 * 1024 * 1024);
    expect(stats['memoryUtilization'], closeTo(0.125, 0.001));
    expect(stats['numProcesses'], 3);
  });

  test('container_stats 停止容器 → isError + CONFLICT', () async {
    bridge.statsFailures['db'] = 'container is not running';
    await initialize();
    final result = await callTool('container_stats', <String, dynamic>{
      'id': 'db',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'CONFLICT');
  });
}
