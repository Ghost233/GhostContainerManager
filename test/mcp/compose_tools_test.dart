import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tools/compose_tools.dart';
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
        registerComposeTools(
          server,
          ComposeService(bridge: bridge, containerService: containers),
        );
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
      'method': 'tools/list',
    });
    final tools = (body['result'] as Map<String, dynamic>)['tools'] as List;
    return <String, Map<String, dynamic>>{
      for (final tool in tools)
        (tool as Map)['name'] as String: tool.cast<String, dynamic>(),
    };
  }

  test('compose run tools declare their structured output schemas', () async {
    final tools = await listTools();
    for (final name in <String>['compose_up', 'compose_down']) {
      final schema = (tools[name]?['outputSchema'] as Map?)
          ?.cast<String, dynamic>();
      expect(schema, isNotNull, reason: name);
      final properties = (schema!['properties'] as Map).cast<String, dynamic>();
      expect(properties.keys, <String>{'exitCode', 'output', 'truncated'});
      expect((properties['exitCode'] as Map)['type'], 'integer', reason: name);
      expect((properties['output'] as Map)['type'], 'string', reason: name);
      expect((properties['truncated'] as Map)['type'], 'boolean', reason: name);
      expect(
        schema['required'],
        containsAll(<String>['exitCode', 'output', 'truncated']),
        reason: name,
      );
    }
  });
}
