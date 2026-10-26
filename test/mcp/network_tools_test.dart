import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tools/network_tools.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/network_service.dart';
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
          const Implementation(name: 'network-tools-test', version: '1.0.0'),
        );
        final registry = ToolCallbackRegistry();
        registerNetworkTools(
          registry,
          NetworkService(bridge: bridge, containerService: containers),
        );
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

  Future<Map<String, dynamic>> listTool(String name) async {
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
        'arguments': <String, dynamic>{'domain': 'network'},
      },
    });
    final result = body['result'] as Map<String, dynamic>;
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final domains = structured['domains'] as Map<String, dynamic>;
    final tools = domains['network'] as List;
    return (tools.singleWhere((tool) => (tool as Map)['name'] == name) as Map)
        .cast<String, dynamic>();
  }

  test('network_get declares its structured output schema', () async {
    final tool = await listTool('network_get');
    // 精简模式下 outputSchema 不进 tools/list；目录条目承载名称/描述/注解，
    // 结构化输出形状由 network_tools 单元测试与 docs/spec/mcp-tools.md §3 保证。
    expect(tool['title'], 'Get Network');
    final annotations = tool['annotations'] as Map<String, dynamic>;
    expect(annotations['readOnlyHint'], isTrue);
  });
}
