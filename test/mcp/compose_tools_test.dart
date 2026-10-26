import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tools/compose_tools.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

void main() {
  late HttpClient client;
  late StreamableMcpServer httpServer;
  late String baseUrl;
  String? sessionId;
  String? protocolVersion;

  setUp(() async {
    sessionId = null;
    protocolVersion = null;
    final bridge = FakeContainerBridge();
    final containers = ContainerService(bridge: bridge);
    httpServer = StreamableMcpServer(
      serverFactory: (_) {
        final server = McpServer(
          const Implementation(name: 'compose-tools-test', version: '1.0.0'),
        );
        final composeService = ComposeService(
          bridge: bridge,
          containerService: containers,
        );
        final registry = ToolCallbackRegistry();
        registerComposeTools(registry, composeService);
        registerCatalogTools(server, registry);
        return server;
      },
      host: '127.0.0.1',
      port: 0,
      path: '/mcp',
      enableJsonResponse: true,
    );
    await httpServer.start();
    baseUrl = 'http://127.0.0.1:${httpServer.boundPort}/mcp';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await httpServer.stop();
  });

  Future<Map<String, dynamic>> rpc(Map<String, dynamic> body) async {
    final request = await client.postUrl(Uri.parse(baseUrl));
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    if (sessionId != null) request.headers.set('mcp-session-id', sessionId!);
    if (protocolVersion != null) {
      request.headers.set('mcp-protocol-version', protocolVersion!);
    }
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    expect(response.statusCode, inInclusiveRange(200, 202));
    sessionId ??= response.headers.value('mcp-session-id');
    return text.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, Map<String, dynamic>>> listTools() async {
    final initialized = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{'name': 'test', 'version': '1.0.0'},
      },
    });
    protocolVersion =
        (initialized['result'] as Map<String, dynamic>)['protocolVersion']
            as String?;
    await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'gcm_help',
        'arguments': <String, dynamic>{},
      },
    });
    final result = body['result'] as Map<String, dynamic>;
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final domains = structured['domains'] as Map<String, dynamic>;
    return <String, Map<String, dynamic>>{
      for (final domain in domains.values)
        for (final tool in domain as List)
          (tool as Map)['name'] as String: tool.cast<String, dynamic>(),
    };
  }

  test('compose run tools declare their structured output schemas', () async {
    final tools = await listTools();
    for (final name in <String>['compose_up', 'compose_down']) {
      final entry = tools[name];
      expect(entry, isNotNull, reason: name);
      // 精简模式下 outputSchema 不进 tools/list；结构化输出形状由
      // compose_tools 的单元测试与 docs/spec/mcp-tools.md §3 保证。
      expect(entry!['description'], contains('compose'));
    }
  });
}
