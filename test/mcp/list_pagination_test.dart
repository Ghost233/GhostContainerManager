import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/container_bridge.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tool_catalog.dart';
import 'package:ghost_container_manager/mcp/tool_registrar.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/mcp/tools/compose_tools.dart';
import 'package:ghost_container_manager/mcp/tools/container_tools.dart';
import 'package:ghost_container_manager/mcp/tools/image_tools.dart';
import 'package:ghost_container_manager/mcp/tools/mount_tools.dart';
import 'package:ghost_container_manager/mcp/tools/network_tools.dart';
import 'package:ghost_container_manager/mcp/tools/project_tools.dart';
import 'package:ghost_container_manager/services/compose_service.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/image_service.dart';
import 'package:ghost_container_manager/services/mount_service.dart';
import 'package:ghost_container_manager/services/network_service.dart';
import 'package:ghost_container_manager/services/project_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../services/container_service_test.dart' show snapshotPayload;

/// End-to-end evidence for issue #31: every list tool shares the same
/// limit/offset pagination contract (default 50, max 500 rejected by schema
/// validation), a stable ascending sort, and a total/returned/hasMore/
/// nextOffset envelope; the text channel degrades to a one-line summary with
/// at most five identifier previews instead of inlined JSON.
void main() {
  late FakeContainerBridge bridge;
  late _FakeProjectService projectService;
  late StreamableMcpServer transport;
  // 每测试新建并在 tearDown 关闭（issue #35 资源卫生）；不能组级共享
  // 后关闭——HttpClient.close 会让后续测试的 postUrl 直接抛 StateError。
  late HttpClient http;

  String? sessionId;
  String? protocolVersion;

  Uri endpoint() => Uri.parse('http://127.0.0.1:${transport.boundPort}/mcp');

  Map<String, Object?> payloadWithMount(String id, String source) {
    final payload = snapshotPayload(
      id: id,
      labels: const {
        'com.compose.project': 'zblog',
        'com.compose.service': 'web',
      },
    );
    (payload['configuration']
        as Map<String, Object?>)['mounts'] = <Map<String, Object?>>[
      <String, Object?>{
        'destination': '/data',
        'options': <String>['rw'],
        'source': source,
        'type': <String, Object?>{'virtiofs': <String, Object?>{}},
      },
    ];
    return payload;
  }

  setUp(() async {
    sessionId = null;
    protocolVersion = null;
    http = HttpClient();
    bridge = FakeContainerBridge()
      ..containers = [
        payloadWithMount('zeta', '/z/src'),
        snapshotPayload(
          id: 'alpha',
          labels: const {
            'com.compose.project': 'ashop',
            'com.compose.service': 'web',
          },
        ),
        snapshotPayload(id: 'mid', status: 'stopped', startedAt: null),
      ]
      ..images = <Map<String, Object?>>[
        <String, Object?>{
          'reference': 'docker.io/library/zed:1',
          'digest': 'sha256:aaa',
          'mediaType': 'application/vnd.oci.image.index.v1+json',
          'sizeBytes': 1024,
        },
        <String, Object?>{
          'reference': 'docker.io/library/alpine:3.19',
          'digest': 'sha256:bbb',
          'mediaType': 'application/vnd.oci.image.index.v1+json',
          'sizeBytes': 2048,
        },
        <String, Object?>{
          'reference': 'docker.io/library/mid:2',
          'digest': 'sha256:ccc',
          'mediaType': 'application/vnd.oci.image.index.v1+json',
          'sizeBytes': 4096,
        },
      ]
      ..networkListResult = const BridgeCommandResult(
        exitCode: 0,
        stdout:
            '[{"configuration":{"name":"zzz","mode":"nat","plugin":"p"},'
            '"status":{"ipv4Subnet":"10.0.0.0/24","ipv4Gateway":"10.0.0.1"}},'
            '{"configuration":{"name":"default","mode":"nat","plugin":"p"},'
            '"status":{"ipv4Subnet":"192.168.64.0/24",'
            '"ipv4Gateway":"192.168.64.1"}}]',
        stderr: '',
      );
    projectService = _FakeProjectService(const [
      ProjectSummary(project: 'zeta', images: [], containers: 0),
      ProjectSummary(project: 'alpha', images: [], containers: 0),
    ]);
    final containerService = ContainerService(bridge: bridge);
    transport = StreamableMcpServer(
      serverFactory: (_) {
        final server = McpServer(
          const Implementation(name: 'pagination-test', version: '0'),
        );
        final registry = ToolCallbackRegistry();
        registerContainerTools(registry, containerService);
        registerImageTools(
          registry,
          ImageService(bridge: bridge, containerService: containerService),
        );
        registerNetworkTools(
          registry,
          NetworkService(bridge: bridge, containerService: containerService),
        );
        registerMountTools(
          registry,
          MountService(containerService: containerService),
        );
        registerComposeTools(
          registry,
          ComposeService(bridge: bridge, containerService: containerService),
        );
        registerProjectTools(registry, projectService);
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
    http.close();
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
          'name': 'pagination-e2e',
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
      'params': <String, dynamic>{
        'name': 'gcm_call',
        'arguments': <String, dynamic>{'tool': name, 'arguments': arguments},
      },
    });
    return body['result'] as Map<String, dynamic>;
  }

  Map<String, dynamic> structured(Map<String, dynamic> result) =>
      result['structuredContent'] as Map<String, dynamic>;

  String summaryText(Map<String, dynamic> result) =>
      (result['content'] as List).first['text'] as String;

  group('schema 声明（六个列表工具统一分页契约）', () {
    const listTools = <String>[
      'container_list',
      'image_list',
      'project_list',
      'network_list',
      'mount_list',
      'compose_list',
    ];

    test('inputSchema 声明 limit（默认 50、1..500）与 offset（默认 0、>=0）', () {
      for (final name in listTools) {
        final entry = catalogEntryByName(name);
        expect(entry, isNotNull, reason: name);
        final properties = entry!.inputSchema.properties!;
        final limit = properties['limit'] as JsonInteger?;
        final offset = properties['offset'] as JsonInteger?;
        expect(limit, isNotNull, reason: '$name.limit');
        expect(limit!.defaultValue, 50, reason: name);
        expect(limit.minimum, 1, reason: name);
        expect(limit.maximum, 500, reason: name);
        expect(offset, isNotNull, reason: '$name.offset');
        expect(offset!.defaultValue, 0, reason: name);
        expect(offset.minimum, 0, reason: name);
      }
    });

    test('outputSchema 声明 total/returned/hasMore/nextOffset 信封', () {
      for (final name in listTools) {
        final entry = catalogEntryByName(name)!;
        final properties = entry.outputSchema.properties!;
        for (final field in ['total', 'returned', 'hasMore', 'nextOffset']) {
          expect(properties, contains(field), reason: '$name.$field');
        }
        expect(properties['total'], isA<JsonInteger>(), reason: name);
        expect(properties['returned'], isA<JsonInteger>(), reason: name);
        expect(properties['hasMore'], isA<JsonBoolean>(), reason: name);
      }
    });
  });

  group('container_list 分页', () {
    test('默认分页：信封完整、按 id 升序、文本为一行摘要', () async {
      await initialize();
      final result = await callTool('container_list', <String, dynamic>{});
      final data = structured(result);
      expect(data['total'], 3);
      expect(data['returned'], 3);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      final containers = data['containers'] as List;
      expect(containers.map((c) => (c as Map)['id']).toList(), [
        'alpha',
        'mid',
        'zeta',
      ]);
      final text = summaryText(result);
      expect(text, contains('共 3 个容器'));
      expect(text, contains('本页 3 个'));
      expect(text, isNot(startsWith('{')));
      expect(text, isNot(startsWith('[')));
    });

    test('翻页走查：limit=2 → nextOffset=2 → 末页 hasMore=false', () async {
      await initialize();
      final page1 = structured(
        await callTool('container_list', <String, dynamic>{'limit': 2}),
      );
      expect(page1['returned'], 2);
      expect(page1['hasMore'], isTrue);
      expect(page1['nextOffset'], 2);
      expect(
        (page1['containers'] as List).map((c) => (c as Map)['id']).toList(),
        ['alpha', 'mid'],
      );
      final page2 = structured(
        await callTool('container_list', <String, dynamic>{
          'limit': 2,
          'offset': page1['nextOffset'],
        }),
      );
      expect(page2['total'], 3);
      expect(page2['returned'], 1);
      expect(page2['hasMore'], isFalse);
      expect(page2['nextOffset'], isNull);
      expect(
        (page2['containers'] as List).map((c) => (c as Map)['id']).toList(),
        ['zeta'],
      );
    });

    test('恰好一页：limit=total 时 hasMore=false、nextOffset=null', () async {
      await initialize();
      final data = structured(
        await callTool('container_list', <String, dynamic>{'limit': 3}),
      );
      expect(data['returned'], 3);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
    });

    test('offset 越界返回空页，信封仍完整', () async {
      await initialize();
      final data = structured(
        await callTool('container_list', <String, dynamic>{'offset': 99}),
      );
      expect(data['total'], 3);
      expect(data['returned'], 0);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      expect(data['containers'], isEmpty);
    });

    test('空列表：total=0、returned=0、hasMore=false、nextOffset=null', () async {
      bridge.containers = <Map<String, Object?>>[];
      await initialize();
      final data = structured(
        await callTool('container_list', <String, dynamic>{}),
      );
      expect(data['total'], 0);
      expect(data['returned'], 0);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      expect(data['containers'], isEmpty);
    });

    test('limit 超过 500 或为 0、offset 为负：INVALID_ARGUMENT', () async {
      await initialize();
      for (final arguments in <Map<String, dynamic>>[
        {'limit': 501},
        {'limit': 0},
        {'offset': -1},
      ]) {
        final result = await callTool('container_list', arguments);
        expect(result['isError'], isTrue, reason: '$arguments');
        expect(structured(result)['error']['code'], 'INVALID_ARGUMENT');
      }
    });

    test('摘要瘦身：7 个容器只预览前 5 个标识并以 … 收尾', () async {
      bridge.containers = [
        for (var i = 1; i <= 7; i++) snapshotPayload(id: 'c0$i'),
      ];
      await initialize();
      final result = await callTool('container_list', <String, dynamic>{});
      final data = structured(result);
      expect(data['total'], 7);
      expect(data['returned'], 7);
      final text = summaryText(result);
      for (var i = 1; i <= 5; i++) {
        expect(text, contains('c0$i'));
      }
      expect(text, isNot(contains('c06')));
      expect(text, isNot(contains('c07')));
      expect(text, contains('…'));
    });
  });

  group('image_list 分页', () {
    test('按 reference 升序，信封完整', () async {
      await initialize();
      final data = structured(
        await callTool('image_list', <String, dynamic>{}),
      );
      expect(data['total'], 3);
      expect(data['returned'], 3);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      final images = data['images'] as List;
      expect(images.map((i) => (i as Map)['reference']).toList(), [
        'docker.io/library/alpine:3.19',
        'docker.io/library/mid:2',
        'docker.io/library/zed:1',
      ]);
      expect(
        summaryText(await callTool('image_list', <String, dynamic>{})),
        contains('共 3 个镜像'),
      );
    });

    test('limit=1 翻页三页后收尾', () async {
      await initialize();
      var offset = 0;
      final seen = <String>[];
      for (var page = 0; page < 3; page++) {
        final data = structured(
          await callTool('image_list', <String, dynamic>{
            'limit': 1,
            'offset': offset,
          }),
        );
        expect(data['returned'], 1);
        expect(data['hasMore'], page < 2);
        seen.add(
          ((data['images'] as List).single as Map)['reference'] as String,
        );
        final next = data['nextOffset'];
        if (next == null) break;
        offset = next as int;
      }
      expect(seen, hasLength(3));
    });
  });

  group('其余列表工具统一信封与排序', () {
    test('network_list：按 id 升序 + 信封', () async {
      await initialize();
      final data = structured(
        await callTool('network_list', <String, dynamic>{}),
      );
      expect(data['total'], 2);
      expect(data['returned'], 2);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      expect((data['networks'] as List).map((n) => (n as Map)['id']).toList(), [
        'default',
        'zzz',
      ]);
    });

    test('mount_list：按 name 升序 + 信封', () async {
      await initialize();
      final data = structured(
        await callTool('mount_list', <String, dynamic>{}),
      );
      expect(data['total'], greaterThanOrEqualTo(1));
      expect(data['returned'], data['total']);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      final names = (data['mounts'] as List)
          .map((m) => (m as Map)['name'])
          .toList();
      final sorted = List.of(names)..sort();
      expect(names, sorted);
      expect(
        summaryText(await callTool('mount_list', <String, dynamic>{})),
        contains('个挂载源'),
      );
    });

    test('compose_list：按 name 升序 + 信封', () async {
      await initialize();
      final data = structured(
        await callTool('compose_list', <String, dynamic>{}),
      );
      expect(data['total'], 2);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      expect(
        (data['projects'] as List).map((p) => (p as Map)['name']).toList(),
        ['ashop', 'zblog'],
      );
    });

    test('project_list：按 project 升序 + 信封', () async {
      await initialize();
      final data = structured(
        await callTool('project_list', <String, dynamic>{}),
      );
      expect(data['total'], 2);
      expect(data['returned'], 2);
      expect(data['hasMore'], isFalse);
      expect(data['nextOffset'], isNull);
      expect(
        (data['projects'] as List).map((p) => (p as Map)['project']).toList(),
        ['alpha', 'zeta'],
      );
      expect(
        summaryText(await callTool('project_list', <String, dynamic>{})),
        contains('共 2 个项目'),
      );
    });

    test('project_list 分页：limit=1 → nextOffset=1 → 末页', () async {
      await initialize();
      final page1 = structured(
        await callTool('project_list', <String, dynamic>{'limit': 1}),
      );
      expect(page1['returned'], 1);
      expect(page1['hasMore'], isTrue);
      expect(page1['nextOffset'], 1);
      final page2 = structured(
        await callTool('project_list', <String, dynamic>{
          'limit': 1,
          'offset': 1,
        }),
      );
      expect(page2['returned'], 1);
      expect(page2['hasMore'], isFalse);
      expect(page2['nextOffset'], isNull);
    });
  });

  group('gcm_help 文本通道', () {
    test('content 是一行摘要而非内嵌 JSON', () async {
      await initialize();
      final body = await rpc(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 42,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': 'gcm_help',
          'arguments': <String, dynamic>{},
        },
      });
      final result = body['result'] as Map<String, dynamic>;
      final text = summaryText(result);
      expect(text, isNot(startsWith('{')));
      expect(text, contains('个工具'));
      expect(text, contains('gcm_call'));
      final data = structured(result);
      expect(data['totalTools'], greaterThan(0));
      expect(data['domains'], isA<Map>());
    });
  });
}

class _FakeProjectService implements ProjectService {
  _FakeProjectService(this.projects);

  List<ProjectSummary> projects;

  @override
  Future<List<ProjectSummary>> listProjects() async => projects;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
