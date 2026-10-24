import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tools/mount_tools.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/mount_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../services/container_service_test.dart' show snapshotPayload;

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
    final payload = snapshotPayload(id: 'shop-web');
    (payload['configuration']
        as Map<String, Object?>)['mounts'] = <Map<String, Object?>>[
      <String, Object?>{
        'destination': '/usr/share',
        'options': <String>['ro'],
        'source': '/Users/x/site',
        'type': <String, Object?>{'virtiofs': <String, Object?>{}},
      },
    ];
    bridge.containers = <Map<String, Object?>>[payload];
    final containers = ContainerService(bridge: bridge);
    httpServer = StreamableMcpServer(
      serverFactory: (_) {
        final server = McpServer(
          const Implementation(name: 'mount-tools-test', version: '1.0.0'),
        );
        registerMountTools(server, MountService(containerService: containers));
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

  Future<void> initialize() async {
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
  }

  test('mount_inspect declares and returns its structured output', () async {
    await initialize();
    final listed = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = (listed['result'] as Map<String, dynamic>)['tools'] as List;
    final tool = (tools.singleWhere(
      (tool) => (tool as Map)['name'] == 'mount_inspect',
    ) as Map).cast<String, dynamic>();
    final schema = (tool['outputSchema'] as Map).cast<String, dynamic>();
    final properties = (schema['properties'] as Map).cast<String, dynamic>();
    expect(properties.keys, <String>{
      'name',
      'type',
      'source',
      'readOnly',
      'usedBy',
    });
    final usedBy = (properties['usedBy'] as Map).cast<String, dynamic>();
    expect(usedBy['type'], 'array');
    final usage = (usedBy['items'] as Map).cast<String, dynamic>();
    expect(
      ((usage['properties'] as Map).cast<String, dynamic>()).keys,
      <String>{'containerId', 'destination', 'readOnly'},
    );
    expect(schema['required'], containsAll(<String>['name', 'usedBy']));

    final called = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'mount_inspect',
        'arguments': <String, dynamic>{'name': '/Users/x/site'},
      },
    });
    final result = called['result'] as Map<String, dynamic>;
    expect(result['isError'], isNot(true));
    final data = (result['structuredContent'] as Map).cast<String, dynamic>();
    expect(data['name'], '/Users/x/site');
    expect(data['type'], 'virtiofs');
    expect(data['source'], '/Users/x/site');
    expect(data['readOnly'], isTrue);
    final usages = data['usedBy'] as List;
    expect((usages.single as Map)['containerId'], 'shop-web');
    expect((usages.single as Map)['destination'], '/usr/share');
  });
}
