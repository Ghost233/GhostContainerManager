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
    expect(
      names,
      containsAll(['system_status', 'system_start', 'system_stop']),
    );
  });

  test('system_status 返回结构化结果（两级错误模型成功路径）', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (status, body, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'system_status',
          'arguments': <String, dynamic>{},
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
    expect(structured['cliVersion'], '1.6.0');
    expect((structured['resources'] as Map)['images'], 3);
    // 成功路径 content 是人工一行摘要，不是整串 JSON。
    final summary = (result['content'] as List).single['text'] as String;
    expect(summary, contains('运行时级别 ready'));
    expect(summary, isNot(startsWith('{')));
  });

  test('system_stop 失败映射为 isError + 错误码（RUNTIME_UNAVAILABLE）', () async {
    bridge.stopResult = const BridgeCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'XPC connection invalid',
    );
    final (sessionId, protocolVersion) = await initialize();
    final (status, body, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'system_stop',
          'arguments': <String, dynamic>{},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    expect(status, 200);
    final result = body!['result'] as Map<String, dynamic>;
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final error = structured['error'] as Map<String, dynamic>;
    expect(error['code'], 'RUNTIME_UNAVAILABLE');
    expect(error['source'], 'cli');
  });

  test('system_stop 成功：返回 stopped 与容器计数', () async {
    bridge.containers = <Map<String, Object?>>[
      <String, Object?>{'status': 'running'},
      <String, Object?>{'status': 'stopped'},
    ];
    final (sessionId, protocolVersion) = await initialize();
    final (status, body, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'system_stop',
          'arguments': <String, dynamic>{},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    expect(status, 200);
    final result = body!['result'] as Map<String, dynamic>;
    expect(result['isError'], isNot(true));
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect(structured['status'], 'stopped');
    expect(structured['containersStopped'], 1);
    final summary = (result['content'] as List).single['text'] as String;
    expect(summary, contains('连带停止 1 个'));
  });

  test('system_start 调用桥接并返回就绪级别', () async {
    final (sessionId, protocolVersion) = await initialize();
    final (status, body, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'system_start',
          'arguments': <String, dynamic>{'installKernel': true},
        },
      },
      sessionId: sessionId,
      protocolVersion: protocolVersion,
    );
    expect(status, 200);
    final result = body!['result'] as Map<String, dynamic>;
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect(structured['level'], 'ready');
    expect(structured['status'], 'running');
    expect(structured['kernelInstalled'], isTrue);
    expect(structured['startupMs'], isA<int>());
    expect(bridge.calls, contains('systemStart installKernel=true'));
    final summary = (result['content'] as List).single['text'] as String;
    expect(summary, contains('运行时已启动'));
  });
}
