import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// End-to-end evidence for issue #16 acceptance 3: an MCP client speaking
/// Streamable HTTP calls the system_* tools and gets structured results;
/// the two-layer error model surfaces tool failures as isError + error code.
void main() {
  late FakeContainerBridge bridge;
  late GcmMcpServer server;
  final http = HttpClient();

  Uri endpoint() => Uri.parse('http://127.0.0.1:${server.boundPort}/mcp');

  setUp(() async {
    bridge = FakeContainerBridge();
    server = GcmMcpServer(
      systemService: SystemService(bridge: bridge),
      containerService: ContainerService(bridge: bridge),
      port: 0,
      enableJsonResponse: true,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  /// Sends one JSON-RPC message; returns (statusCode, decoded body, headers).
  Future<(int, Map<String, dynamic>?, HttpHeaders)> rpc(
    Map<String, dynamic> message, {
    String? sessionId,
    String? protocolVersion,
  }) async {
    final request = await http.postUrl(endpoint());
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
    Map<String, dynamic>? decoded;
    if (body.trim().isNotEmpty) {
      final mime = response.headers.contentType?.mimeType ?? '';
      if (mime == 'text/event-stream') {
        final dataLine = const LineSplitter()
            .convert(body)
            .lastWhere((l) => l.startsWith('data:'))
            .substring(5)
            .trim();
        decoded = jsonDecode(dataLine) as Map<String, dynamic>;
      } else {
        decoded = jsonDecode(body) as Map<String, dynamic>;
      }
    }
    return (response.statusCode, decoded, response.headers);
  }

  /// Performs the initialize handshake; returns (sessionId, protocolVersion).
  Future<(String?, String?)> initialize() async {
    final (status, body, headers) = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, dynamic>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{'name': 'e2e-test', 'version': '0.0.0'},
      },
    });
    expect(status, 200);
    expect(body!['result'], isNotNull);
    final protocolVersion =
        (body['result'] as Map<String, dynamic>)['protocolVersion'] as String?;
    final sessionId = headers.value('mcp-session-id');
    // notifications/initialized
    final (notifyStatus, _, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    expect(notifyStatus, 202);
    return (sessionId, protocolVersion);
  }

  test('initialize 握手成功并声明 tools 能力', () async {
    final (sessionId, protocolVersion) = await initialize();
    expect(protocolVersion, isNotNull);
    expect(sessionId, isNotNull);

    final (status, body, _) = await rpc(
      <String, dynamic>{'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    expect(status, 200);
    final tools = (body!['result'] as Map<String, dynamic>)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name']).toSet();
    expect(names, containsAll(['gcm_help', 'gcm_call']));
  });

  test('system_status 返回结构化结果（两级错误模型成功路径）', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (status, body, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'gcm_call',
          'arguments': <String, dynamic>{
            'tool': 'system_status',
            'arguments': <String, dynamic>{},
          },
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    expect(status, 200);
    final result = body!['result'] as Map<String, dynamic>;
    expect(result['isError'], isNot(true));
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect(structured['level'], 'ready');
    expect(structured['ready'], isTrue);
    expect(structured['versionSupported'], isTrue);
    expect(structured['cliVersion'], '29.8.2');
    expect((structured['resources'] as Map)['images'], 3);
    // 成功路径 content 是人工一行摘要，不是整串 JSON。
    final summary = (result['content'] as List).single['text'] as String;
    expect(summary, contains('运行时级别 ready'));
    expect(summary, isNot(startsWith('{')));
  });

  test('Docker lifecycle HTTP contract 1', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (_, body, _) = await rpc(
      {
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'gcm_call',
          'arguments': {'tool': 'system_stop', 'arguments': {}},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    final result = body!['result'] as Map;
    expect(result['isError'], isTrue);
    expect(
      (result['structuredContent'] as Map)['error']['code'],
      'INVALID_ARGUMENT',
    );
    expect(
      bridge.calls.where(
        (c) => c.startsWith('systemStart') || c.startsWith('systemStop'),
      ),
      isEmpty,
    );
  });
  test('Docker lifecycle HTTP contract 2', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (_, body, _) = await rpc(
      {
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'gcm_call',
          'arguments': {'tool': 'system_stop', 'arguments': {}},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    final result = body!['result'] as Map;
    expect(result['isError'], isTrue);
    expect(
      (result['structuredContent'] as Map)['error']['code'],
      'INVALID_ARGUMENT',
    );
    expect(
      bridge.calls.where(
        (c) => c.startsWith('systemStart') || c.startsWith('systemStop'),
      ),
      isEmpty,
    );
  });
  test('Docker lifecycle HTTP contract 3', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (_, body, _) = await rpc(
      {
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'gcm_call',
          'arguments': {'tool': 'system_start', 'arguments': {}},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    final result = body!['result'] as Map;
    expect(result['isError'], isNot(true));
    expect((result['structuredContent'] as Map)['ready'], isTrue);
    expect(
      bridge.calls.where(
        (c) => c.startsWith('systemStart') || c.startsWith('systemStop'),
      ),
      isEmpty,
    );
  });
  test('Docker lifecycle HTTP contract 4', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (_, body, _) = await rpc(
      {
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'gcm_call',
          'arguments': {
            'tool': 'system_start',
            'arguments': {'appRoot': '/host'},
          },
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    final result = body!['result'] as Map;
    expect(result['isError'], isTrue);
    expect(
      (result['structuredContent'] as Map)['error']['code'],
      'INVALID_ARGUMENT',
    );
    expect(
      bridge.calls.where(
        (c) => c.startsWith('systemStart') || c.startsWith('systemStop'),
      ),
      isEmpty,
    );
  });
  test('Docker lifecycle HTTP contract 5', () async {
    bridge.statusResult = const BridgeCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'Cannot connect',
    );
    final (sessionId, protocolVersion) = await initialize();
    final (_, body, _) = await rpc(
      {
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'gcm_call',
          'arguments': {'tool': 'system_start', 'arguments': {}},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    final result = body!['result'] as Map;
    expect(result['isError'], isTrue);
    expect(
      (result['structuredContent'] as Map)['error']['code'],
      'RUNTIME_UNAVAILABLE',
    );
    expect(
      bridge.calls.where(
        (c) => c.startsWith('systemStart') || c.startsWith('systemStop'),
      ),
      isEmpty,
    );
  });
}
