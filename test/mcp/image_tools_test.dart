import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tools/image_tools.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../services/container_service_test.dart' show snapshotPayload;

/// End-to-end evidence for issue #20 acceptance 4: an MCP client speaking
/// Streamable HTTP calls image_list / image_inspect / image_delete /
/// image_pull; digest addressing is rejected by Service-layer input
/// validation with a hint; annotations mark every image tool open-world.
/// This file builds its own McpServer (lead wires GcmMcpServer separately),
/// exactly how the production registration will be called.
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
      ..images = [
        <String, Object?>{
          'reference': 'docker.io/library/alpine:3.19',
          'digest': 'sha256:abc123',
          'mediaType': 'application/vnd.oci.image.index.v1+json',
          'sizeBytes': 4096,
          'createdAt': '2026-10-20T08:00:00Z',
        },
        <String, Object?>{
          'reference': 'docker.io/library/alpine', // untagged → dangling
          'digest': 'sha256:def456',
          'mediaType': 'application/vnd.oci.image.index.v1+json',
          'sizeBytes': 4096,
        },
      ];
    final imageService = ImageService(
      bridge: bridge,
      containerService: ContainerService(bridge: bridge),
    );
    transport = StreamableMcpServer(
      serverFactory: (sessionId) {
        final server = McpServer(
          const Implementation(name: 'gcm-test', version: '0.0.0'),
        );
        final registry = ToolCallbackRegistry();
        registerImageTools(registry, imageService);
        registerCatalogTools(server, registry);
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
        'clientInfo': <String, dynamic>{'name': 'image-e2e', 'version': '0'},
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
      'params': <String, dynamic>{
        'name': 'gcm_call',
        'arguments': <String, dynamic>{'tool': name, 'arguments': arguments},
      },
    });
    return body['result'] as Map<String, dynamic>;
  }

  test('tools/list 含四个镜像工具且注解 openWorld', () async {
    await initialize();
    final body = await rpc(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': 'gcm_help',
        'arguments': <String, dynamic>{'domain': 'image'},
      },
    });
    final structured =
        (body['result'] as Map<String, dynamic>)['structuredContent']
            as Map<String, dynamic>;
    final tools =
        (structured['domains'] as Map<String, dynamic>)['image'] as List;
    final byName = <String, Map<String, dynamic>>{
      for (final t in tools) (t as Map)['name'] as String: t.cast(),
    };
    const expectedTitles = <String, String>{
      'image_list': 'List Images',
      'image_inspect': 'Inspect Image',
      'image_delete': 'Delete Image',
      'image_pull': 'Pull Image',
    };
    expect(byName.keys, containsAll(expectedTitles.keys));
    for (final entry in expectedTitles.entries) {
      expect(byName[entry.key]?['title'], entry.value, reason: entry.key);
    }
    for (final name in byName.keys) {
      final annotations = byName[name]!['annotations'] as Map<String, dynamic>;
      expect(annotations['openWorldHint'], isTrue, reason: name);
    }
    final delete = byName['image_delete']!['annotations'] as Map;
    expect(delete['destructiveHint'], isTrue);
    expect(delete['readOnlyHint'], isFalse);
    final pull = byName['image_pull']!['annotations'] as Map;
    expect(pull['destructiveHint'], isFalse);
    // 精简模式下 inputSchema 不进 tools/list；reference 契约由 Service 层
    // 输入校验保证（见下方 digest 寻址用例）。
  });

  test('image_list 返回 structuredContent（含 dangling 标记）与文本摘要', () async {
    await initialize();
    final result = await callTool('image_list', <String, dynamic>{});
    expect(result['isError'], isNot(true));
    final structured = result['structuredContent'] as Map<String, dynamic>;
    final images = structured['images'] as List;
    expect(images, hasLength(2));
    final first = images.first as Map;
    expect(first['reference'], 'docker.io/library/alpine:3.19');
    expect(first['dangling'], isFalse);
    expect(first['sizeBytes'], 4096);
    expect((images[1] as Map)['dangling'], isTrue);
    expect(
      ((result['content'] as List).first as Map)['text'],
      contains('共 2 个镜像'),
    );
  });

  test('image_inspect 返回配置摘要', () async {
    const ref = 'docker.io/library/alpine:3.19';
    bridge.imageInspectResponses[ref] = <String, Object?>{
      'reference': ref,
      'digest': 'sha256:abc123',
      'sizeBytes': 7340032,
      'layers': 2,
      'platforms': <String>['linux/arm64'],
      'config': <String, Object?>{
        'env': <String>['PATH=/usr/bin'],
        'entrypoint': <String>['/bin/sh'],
        'cmd': <String>[],
        'exposedPorts': <String>[],
        'labels': <String, String>{},
      },
    };
    await initialize();
    final result = await callTool('image_inspect', <String, dynamic>{
      'reference': ref,
    });
    expect(result['isError'], isNot(true));
    final image =
        (result['structuredContent'] as Map<String, dynamic>)['image'] as Map;
    expect(image['layers'], 2);
    expect(image['platforms'], ['linux/arm64']);
    expect((image['config'] as Map)['env'], ['PATH=/usr/bin']);
  });

  test('image_delete digest 寻址 → isError + INVALID_ARGUMENT + hint', () async {
    await initialize();
    final result = await callTool('image_delete', <String, dynamic>{
      'reference': 'alpine@sha256:${'a' * 64}',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'INVALID_ARGUMENT');
    expect((structured['error'] as Map)['hint'], contains('name:tag'));
    expect(bridge.deletedImages, isEmpty);
  });

  test('image_delete 被容器引用 → isError + CONFLICT', () async {
    bridge.containers = [
      snapshotPayload(id: 'web', image: 'docker.io/library/alpine:3.19'),
    ];
    await initialize();
    final result = await callTool('image_delete', <String, dynamic>{
      // Pre-check matches the exact stored reference (no tag defaulting
      // across registries), so the full reference is used here.
      'reference': 'docker.io/library/alpine:3.19',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'CONFLICT');
    expect((structured['error'] as Map)['message'], contains('web'));
  });

  test('image_pull 成功返回引用与摘要', () async {
    await initialize();
    final result = await callTool('image_pull', <String, dynamic>{
      'reference': 'docker.io/library/alpine:3.20',
    });
    expect(result['isError'], isNot(true));
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect(structured['reference'], 'docker.io/library/alpine:3.20');
    expect(structured['digest'], 'sha256:${'a' * 64}');
    expect(bridge.pullCalls.single, contains('docker.io/library/alpine:3.20'));
    expect(bridge.pullCalls.single, endsWith(' -')); // platform 缺省
  });

  test('image_pull 失败 → isError + RUNTIME_UNAVAILABLE', () async {
    bridge.pullFailure = 'connection invalid';
    await initialize();
    final result = await callTool('image_pull', <String, dynamic>{
      'reference': 'alpine:3.20',
    });
    expect(result['isError'], isTrue);
    final structured = result['structuredContent'] as Map<String, dynamic>;
    expect((structured['error'] as Map)['code'], 'RUNTIME_UNAVAILABLE');
    expect((structured['error'] as Map)['source'], 'xpc');
  });
}
