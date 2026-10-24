import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/mcp_server.dart';
import 'package:ghost_container_manager/mcp/stdio_proxy.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';

/// stdio thin-proxy evidence: the proxy forwards newline-delimited JSON-RPC
/// to the Streamable HTTP endpoint, tracks the session, and returns the
/// same structured results a stdio MCP client would see.
void main() {
  late GcmMcpServer server;

  setUp(() async {
    server = GcmMcpServer(
      systemService: SystemService(
        bridge: FakeContainerBridge(),
        pingInterval: Duration.zero,
      ),
      containerService: ContainerService(bridge: FakeContainerBridge()),
      port: 0,
      enableJsonResponse: true,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  test('forward: initialize → notification 202 → tools/call 结构化结果', () async {
    final proxy = McpStdioProxy(port: server.boundPort);

    final initResponse = await proxy.forward(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{
            'name': 'stdio-e2e',
            'version': '0.0.0',
          },
        },
      }),
    );
    expect(initResponse, isNotNull);
    final init = jsonDecode(initResponse!) as Map<String, dynamic>;
    expect((init['result'] as Map)['protocolVersion'], isNotNull);

    // Notifications produce no stdout line (HTTP 202).
    final notification = await proxy.forward(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }),
    );
    expect(notification, isNull);

    final callResponse = await proxy.forward(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'system_status',
          'arguments': <String, dynamic>{},
        },
      }),
    );
    expect(callResponse, isNotNull);
    final call = jsonDecode(callResponse!) as Map<String, dynamic>;
    final structured =
        (call['result'] as Map)['structuredContent'] as Map<String, dynamic>;
    expect(structured['level'], 'ready');
    expect(structured['cliVersion'], '1.6.0');
  });

  test('forward: SSE 响应解包最后一个 data 行', () async {
    // Rebuild a server without enableJsonResponse so replies come as SSE.
    await server.stop();
    server = GcmMcpServer(
      systemService: SystemService(
        bridge: FakeContainerBridge(),
        pingInterval: Duration.zero,
      ),
      containerService: ContainerService(bridge: FakeContainerBridge()),
      port: 0,
    );
    await server.start();
    final proxy = McpStdioProxy(port: server.boundPort);

    final initResponse = await proxy.forward(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{
            'name': 'stdio-sse',
            'version': '0.0.0',
          },
        },
      }),
    );
    expect(initResponse, isNotNull);
    final init = jsonDecode(initResponse!) as Map<String, dynamic>;
    expect(init['result'], isNotNull);
  });
}
