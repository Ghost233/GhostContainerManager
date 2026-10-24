import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// End-to-end evidence for issue #16 "最近调用简表": a real `tools/call`
/// over the in-app Streamable HTTP transport lands in [GcmMcpServer.recentCalls].
void main() {
  test('tool calls are recorded in the bounded audit trail', () async {
    final bridge = FakeContainerBridge();
    final systemService = SystemService(
      bridge: bridge,
      pingInterval: Duration.zero,
    );
    final containerService = ContainerService(bridge: bridge);
    final server = GcmMcpServer(
      systemService: systemService,
      containerService: containerService,
      port: 0,
      enableJsonResponse: true,
    );
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
          'name': 'audit-test',
          'version': '0.0.0',
        },
      },
    });
    final negotiatedVersion =
        (initBody!['result'] as Map<String, dynamic>)['protocolVersion']
            as String?;

    await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
      sessionId: sessionId,
      protocolVersion: negotiatedVersion,
    );

    expect(server.recentCalls, isEmpty);

    final (callBody, _, _) = await rpc(
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'system_status',
          'arguments': <String, dynamic>{},
        },
      },
      sessionId: sessionId,
      protocolVersion: negotiatedVersion,
    );
    expect((callBody?['result'] as Map)['isError'], isNot(true));

    expect(server.recentCalls, hasLength(1));
    final record = server.recentCalls.single;
    expect(record.tool, 'system_status');
    expect(record.succeeded, isTrue);
    expect(record.duration, isA<Duration>());
  });
}
