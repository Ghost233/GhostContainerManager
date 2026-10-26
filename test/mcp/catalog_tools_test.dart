import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_container_manager/bridge/fake_container_bridge.dart';
import 'package:ghost_container_manager/mcp/tool_catalog.dart';
import 'package:ghost_container_manager/mcp/tools/catalog_tools.dart';
import 'package:ghost_container_manager/services/container_service.dart';
import 'package:ghost_container_manager/services/system_service.dart';
import 'package:mcp_dart/mcp_dart.dart';

void main() {
  group('tool catalog', () {
    test('35 entries across eight domains, matching the v1 spec', () {
      expect(kToolCatalog, hasLength(35));
      final byDomain = catalogByDomain();
      expect(byDomain.keys, <String>[
        'system',
        'container',
        'image',
        'mount',
        'network',
        'compose',
        'project',
        'registry',
      ]);
      expect(byDomain['system'], hasLength(3));
      expect(byDomain['container'], hasLength(10));
      expect(byDomain['image'], hasLength(4));
      expect(byDomain['mount'], hasLength(2));
      expect(byDomain['network'], hasLength(2));
      expect(byDomain['compose'], hasLength(3));
      expect(byDomain['project'], hasLength(8));
      expect(byDomain['registry'], hasLength(3));
    });

    test('catalogEntryByName resolves known and rejects unknown', () {
      expect(catalogEntryByName('container_list')?.domain, 'container');
      expect(
        catalogEntryByName('registry_stop')?.annotations.destructiveHint,
        isTrue,
      );
      expect(catalogEntryByName('nope'), isNull);
    });

    test('every catalog entry has a non-empty title and description', () {
      for (final entry in kToolCatalog) {
        expect(entry.title, isNotEmpty, reason: entry.name);
        expect(entry.description, isNotEmpty, reason: entry.name);
      }
    });

    test(
      'every entry declares both schemas and all five annotation fields',
      () {
        // issue #29：注册表是唯一事实来源，每个条目必须自带 inputSchema、
        // outputSchema 与完整五字段注解（title/RO/D/I/OW），gcm_help、
        // gcm_call 分发校验与测试全部从这里读。
        for (final entry in kToolCatalog) {
          expect(entry.inputSchema, isNotNull, reason: entry.name);
          expect(entry.outputSchema, isNotNull, reason: entry.name);
          final annotations = entry.annotations;
          expect(annotations.title, isNotEmpty, reason: entry.name);
          expect(annotations.readOnlyHint, isA<bool>(), reason: entry.name);
          expect(annotations.destructiveHint, isA<bool>(), reason: entry.name);
          expect(annotations.idempotentHint, isA<bool>(), reason: entry.name);
          // 规格 §3：所有工具操作本机运行时，openWorldHint 一律 true。
          expect(annotations.openWorldHint, isTrue, reason: entry.name);
        }
      },
    );

    test('entry domain matches the tool name prefix', () {
      for (final entry in kToolCatalog) {
        expect(
          entry.name.startsWith('${entry.domain}_'),
          isTrue,
          reason: '${entry.name} in domain ${entry.domain}',
        );
      }
    });

    test('catalog annotations mirror the spec RO/D/I decisions', () {
      // 抽查规格 §3 表中的代表性注解（readOnly/destructive/idempotent）。
      final expected = <String, (bool ro, bool d, bool i)>{
        'system_status': (true, false, true),
        'system_stop': (false, true, true),
        'container_create': (false, false, false),
        'container_kill': (false, true, true),
        'container_exec': (false, false, false),
        'image_delete': (false, true, true),
        'compose_down': (false, true, true),
        'project_init': (false, false, false),
        'project_reclaim': (false, true, true),
        'registry_stop': (false, true, true),
      };
      for (final sample in expected.entries) {
        final entry = catalogEntryByName(sample.key);
        expect(entry, isNotNull, reason: sample.key);
        expect(
          entry!.annotations.readOnlyHint,
          sample.value.$1,
          reason: sample.key,
        );
        expect(
          entry.annotations.destructiveHint,
          sample.value.$2,
          reason: sample.key,
        );
        expect(
          entry.annotations.idempotentHint,
          sample.value.$3,
          reason: sample.key,
        );
      }
    });

    test('idempotentHint 与生命周期并发契约逐一核对（issue #32，穷举 35 条）', () {
      // 对照 docs/spec/container-lifecycle.md §3 并发契约核对：
      // start/stop/kill 幂等（重试无额外效果）；delete 对 notFound 视为
      // 成功（幂等）；create 重名报 CONFLICT（非幂等）；restart 每次执行
      // 都是一个完整的 stop+start 周期——合成、非原子、重复调用有额外效果
      // （MCP idempotentHint 语义），故非幂等；exec 每次在容器内真实执行
      // 进程，非幂等。与上面 #30 的抽样测试共存：这张表是穷举断言。
      const expected = <String, bool>{
        'system_status': true,
        'system_start': true,
        'system_stop': true,
        'container_list': true,
        'container_inspect': true,
        'container_stats': true,
        'container_create': false,
        'container_start': true,
        'container_stop': true,
        'container_restart': false,
        'container_kill': true,
        'container_delete': true,
        'container_exec': false,
        'image_list': true,
        'image_inspect': true,
        'image_delete': true,
        'image_pull': true,
        'mount_list': true,
        'mount_inspect': true,
        'network_list': true,
        'network_get': true,
        'compose_list': true,
        'compose_up': true,
        'compose_down': true,
        'project_list': true,
        'project_get': true,
        'project_init': false,
        'project_build': false,
        'project_test': false,
        'project_reclaim': true,
        'project_publish': true,
        'project_restore': true,
        'registry_status': true,
        'registry_start': true,
        'registry_stop': true,
      };
      expect(kToolCatalog, hasLength(expected.length));
      for (final entry in kToolCatalog) {
        expect(
          expected.containsKey(entry.name),
          isTrue,
          reason: '穷举表缺少 ${entry.name}',
        );
        expect(
          entry.annotations.idempotentHint,
          expected[entry.name],
          reason: entry.name,
        );
      }
    });
  });

  group('buildBusinessToolRegistry', () {
    test('collects only wired domains (system + container here)', () {
      final bridge = FakeContainerBridge();
      final registry = buildBusinessToolRegistry(
        systemService: SystemService(bridge: bridge),
        containerService: ContainerService(bridge: bridge),
      );
      expect(
        registry.callbacks.keys,
        containsAll(<String>[
          'system_status',
          'system_start',
          'system_stop',
          'container_list',
          'container_exec',
        ]),
      );
      expect(registry.callbacks, hasLength(13));
      expect(registry.callbacks.containsKey('image_list'), isFalse);
    });
  });

  group('ToolCallbackRegistry 定义快照（issue #29 验收 4）', () {
    test('注册时保存完整定义快照，元数据即注册表条目本身', () {
      final bridge = FakeContainerBridge();
      final registry = buildBusinessToolRegistry(
        systemService: SystemService(bridge: bridge),
        containerService: ContainerService(bridge: bridge),
      );
      expect(registry.tools, hasLength(13));
      for (final snapshot in registry.tools.values) {
        final entry = catalogEntryByName(snapshot.name);
        expect(entry, isNotNull, reason: snapshot.name);
        // registerCatalogTool 透传条目对象本身：快照与注册表不可能漂移。
        expect(
          identical(snapshot.inputSchema, entry!.inputSchema),
          isTrue,
          reason: snapshot.name,
        );
        expect(
          identical(snapshot.outputSchema, entry.outputSchema),
          isTrue,
          reason: snapshot.name,
        );
        expect(
          identical(snapshot.annotations, entry.annotations),
          isTrue,
          reason: snapshot.name,
        );
        expect(snapshot.title, entry.title, reason: snapshot.name);
        expect(snapshot.description, entry.description, reason: snapshot.name);
      }
    });

    test('callbacks 是由快照派生的只读视图', () {
      final bridge = FakeContainerBridge();
      final registry = buildBusinessToolRegistry(
        systemService: SystemService(bridge: bridge),
        containerService: ContainerService(bridge: bridge),
      );
      expect(
        registry.callbacks.keys,
        registry.tools.keys,
        reason: 'callbacks 必须覆盖全部已注册工具',
      );
      for (final name in registry.tools.keys) {
        expect(
          identical(registry.callbacks[name], registry.tools[name]!.callback),
          isTrue,
          reason: name,
        );
      }
    });
  });

  group('gcm_help/gcm_call 以注册快照为准（部分接线 e2e）', () {
    late HttpClient client;
    late StreamableMcpServer httpServer;
    String? sessionId;
    String? protocolVersion;

    setUp(() async {
      sessionId = null;
      protocolVersion = null;
      final bridge = FakeContainerBridge();
      httpServer = StreamableMcpServer(
        serverFactory: (_) {
          final server = McpServer(
            const Implementation(name: 'catalog-snapshot-test', version: '0'),
          );
          registerCatalogTools(
            server,
            buildBusinessToolRegistry(
              systemService: SystemService(bridge: bridge),
              containerService: ContainerService(bridge: bridge),
            ),
          );
          return server;
        },
        host: '127.0.0.1',
        port: 0,
        path: '/mcp',
        enableJsonResponse: true,
      );
      await httpServer.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await httpServer.stop();
    });

    Future<Map<String, dynamic>> rpc(Map<String, dynamic> body) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${httpServer.boundPort}/mcp'),
      );
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

    var nextId = 100;
    Future<Map<String, dynamic>> callTool(
      String name,
      Map<String, dynamic> arguments,
    ) async {
      final body = await rpc(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': nextId++,
        'method': 'tools/call',
        'params': <String, dynamic>{'name': name, 'arguments': arguments},
      });
      return body['result'] as Map<String, dynamic>;
    }

    test('gcm_help 只列出已接线的 13 个工具，未接线域不出现', () async {
      await initialize();
      final result = await callTool('gcm_help', <String, dynamic>{});
      final structured = result['structuredContent'] as Map<String, dynamic>;
      expect(structured['totalTools'], 13);
      expect((structured['domains'] as Map<String, dynamic>).keys, <String>[
        'system',
        'container',
      ]);
    });

    test('gcm_help 过滤未接线域返回空目录', () async {
      await initialize();
      final result = await callTool('gcm_help', <String, dynamic>{
        'domain': 'image',
      });
      final structured = result['structuredContent'] as Map<String, dynamic>;
      expect(structured['totalTools'], 0);
      expect(structured['domains'], isEmpty);
    });

    test('gcm_call 调未接线的已知工具返回 NOT_FOUND', () async {
      await initialize();
      final result = await callTool('gcm_call', <String, dynamic>{
        'tool': 'image_list',
        'arguments': <String, dynamic>{},
      });
      expect(result['isError'], isTrue);
      final structured = (result['structuredContent'] as Map)
          .cast<String, dynamic>();
      expect((structured['error'] as Map)['code'], 'NOT_FOUND');
    });
  });
}
